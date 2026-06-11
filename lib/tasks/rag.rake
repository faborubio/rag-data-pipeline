namespace :rag do
  desc "Run RAG quality evals (recall@k, MRR, keyword presence) against the golden set"
  task evals: :environment do
    report = nil
    # Roll back everything: the golden corpus must never pollute the database.
    ActiveRecord::Base.transaction do
      report = Rag::Evals::Runner.new.run
      raise ActiveRecord::Rollback
    end

    thresholds = Rag::Evals::Runner::THRESHOLDS
    tier = Rag::Embedder.new.live? ? "live (OpenAI)" : "fallback (lexical, deterministic)"

    puts
    puts "RAG quality evals — tier: #{tier} — k=#{report.k}"
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
    puts format("recall@%d: %.3f (min %.2f) | MRR: %.3f (min %.2f) | keywords: %.3f (min %.2f)",
                report.k, report.recall_at_k, thresholds[:recall_at_k],
                report.mrr, thresholds[:mrr],
                report.keyword_presence, thresholds[:keyword_presence])

    if report.pass?
      puts "PASS"
    else
      abort "FAIL: evals below thresholds"
    end
  end
end
