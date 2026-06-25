namespace :rag do
  desc "Re-embed every stored chunk with the current embedder (run after switching provider)"
  task reembed: :environment do
    embedder = Rag::Embedder.new
    provider = embedder.provider.to_s
    puts "Re-embedding with provider: #{provider}"
    total = DocumentChunk.count
    done = 0
    DocumentChunk.in_batches(of: Rag::Embedder::BATCH_SIZE) do |batch|
      chunks = batch.to_a
      vectors = embedder.embed(chunks.map(&:content))
      # Stamp the provider alongside the vector so the ingestor's content_hash +
      # provider idempotency stays correct (otherwise a re-ingest would see a
      # stale provider and needlessly re-embed, or reuse a vector from the wrong space).
      chunks.each_with_index { |chunk, i| chunk.update_columns(embedding: vectors[i], embedding_provider: provider) }
      done += chunks.size
      puts "  #{done}/#{total}"
    end
    puts "Done."
  end

  desc "Ingest a local PDF, resumable across runs (free-tier friendly). " \
       "Usage: rake 'rag:ingest[/abs/path.pdf,Tenant Name]'"
  task :ingest, [ :path, :tenant ] => :environment do |_t, args|
    path = args.path or abort "path required: rake 'rag:ingest[/abs/path.pdf,Tenant]'"
    abort "no such file: #{path}" unless File.exist?(path)

    tenant = Tenant.find_or_create_by!(name: args.tenant.presence || "Local Ingest")
    document = tenant.documents.find_or_create_by!(filename: File.basename(path)) do |d|
      d.status = :processing
    end
    embedder = Rag::Embedder.new
    puts "Ingesting #{File.basename(path)} into '#{tenant.name}' (provider=#{embedder.provider})"

    begin
      count = Rag::Ingestor.new(embedder: embedder).call(document, path)
      document.completed!
      puts "DONE: #{count} chunks embedded and stored."
    rescue Rag::Embedder::RateLimitError
      # Every batch embedded so far is cached; re-running resumes from there.
      puts "Rate limit reached — partial progress is cached."
      puts "Re-run the same command later to resume (only the remaining chunks are fetched)."
    end
  end

  desc "Run RAG quality evals (recall@k, MRR, keyword presence) against the golden set"
  task evals: :environment do
    report = nil
    # Roll back everything: the golden corpus must never pollute the database.
    ActiveRecord::Base.transaction do
      report = Rag::Evals::Runner.new.run
      raise ActiveRecord::Rollback
    end

    thresholds = Rag::Evals::Runner::THRESHOLDS
    reranker = ENV["RERANKER"] == "neural" ? "neural" : "lexical"

    puts
    puts "RAG quality evals — embeddings: #{Rag::Embedder.new.provider} — reranker: #{reranker} — k=#{report.k}"
    puts format("%-8s %-4s %-5s %-5s %s", "ID", "HIT", "RANK", "KW", "QUESTION")
    puts "-" * 78
    report.rows.each do |row|
      puts format("%-8s %-4s %-5s %-5s %s",
                  row.id,
                  row.recall.positive? ? "yes" : "NO",
                  row.rank || "-",
                  format("%.2f", row.keyword_presence),
                  row.question.truncate(45))
    end
    puts "-" * 78

    unless report.negative_rows.empty?
      puts
      puts "Abstention — preguntas FUERA del corpus (deben abstenerse):"
      puts format("%-8s %-10s %s", "ID", "ABSTAINED", "QUESTION")
      puts "-" * 78
      report.negative_rows.each do |row|
        puts format("%-8s %-10s %s", row.id, row.abstained ? "yes" : "NO", row.question.truncate(50))
      end
      puts "-" * 78
    end

    abstention_note = report.abstention_gated ? format("%.3f (min %.2f)", report.abstention, thresholds[:abstention]) : "n/a (reranker lexico no abstiene)"
    puts format("recall@%d: %.3f (min %.2f) | MRR: %.3f (min %.2f) | keywords: %.3f (min %.2f) | grounding: %.3f (min %.2f)",
                report.k, report.recall_at_k, thresholds[:recall_at_k],
                report.mrr, thresholds[:mrr],
                report.keyword_presence, thresholds[:keyword_presence],
                report.grounding, thresholds[:grounding])
    puts format("false_abstention: %.3f (max %.2f) | abstention: %s",
                report.false_abstention, thresholds[:false_abstention], abstention_note)

    if report.pass?
      puts "PASS"
    else
      abort "FAIL: evals below thresholds"
    end
  end
end
