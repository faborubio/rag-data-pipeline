require "digest"

module Rag
  # Write Path orchestration: extract -> chunk -> embed (batched) -> persist.
  # Page numbers are preserved so the Read Path can cite exact sources.
  class Ingestor
    # Rows per INSERT statement on persist; caps statement size for big documents.
    INSERT_BATCH_SIZE = 500

    def initialize(extractor: PdfTextExtractor.new,
                   chunker: SemanticChunker.new,
                   embedder: Embedder.new)
      @extractor = extractor
      @chunker = chunker
      @embedder = embedder
    end

    # Returns the number of chunks persisted.
    def call(document, file_path)
      Rag.tracer.in_span("rag.ingest", attributes: { "rag.document.id" => document.id.to_s }) do |span|
        pages = Rag.tracer.in_span("rag.extract") { @extractor.extract(file_path) }

        pending = Rag.tracer.in_span("rag.chunk") do
          chunks = []
          pages.each do |page|
            @chunker.chunk(page[:text]).each do |content|
              chunks << { content: content, page_number: page[:page] }
            end
          end
          chunks
        end

        span.add_attributes("rag.pages.count" => pages.size, "rag.chunks.count" => pending.size)
        next 0 if pending.empty?

        provider = @embedder.provider.to_s
        pending.each { |chunk| chunk[:content_hash] = digest_for(chunk[:content]) }

        embeddings = Rag.tracer.in_span("rag.embed", attributes: { "rag.chunks.count" => pending.size }) do
          embed_with_reuse(pending, provider)
        end
        pending.each_with_index { |chunk, i| chunk[:embedding] = embeddings[i] }

        # Bulk insert in a single statement instead of one INSERT per chunk: a
        # large document (100+ chunks) collapses from 100+ round-trips to one.
        # insert_all! skips validations/callbacks, so set timestamps explicitly.
        now = Time.current
        rows = pending.map do |chunk|
          { document_id: document.id, content: chunk[:content], page_number: chunk[:page_number],
            embedding: chunk[:embedding], content_hash: chunk[:content_hash],
            embedding_provider: provider, created_at: now, updated_at: now }
        end

        # Delete via the model (not the association) so we don't load and cache
        # an empty target: insert_all! writes straight to SQL, which would leave
        # a stale in-memory association on the passed-in document.
        DocumentChunk.transaction do
          DocumentChunk.where(document_id: document.id).delete_all
          # Insert in slices so a large document (thousands of chunks) doesn't
          # build one enormous INSERT statement; still one atomic transaction.
          rows.each_slice(INSERT_BATCH_SIZE) { |slice| DocumentChunk.insert_all!(slice) }
        end

        rows.size
      end
    end

    private

    # SHA256 hex of the chunk content. Mirrors the migration's
    # encode(public.digest(content, 'sha256'), 'hex') so the backfill and live
    # writes produce identical hashes.
    def digest_for(content)
      Digest::SHA256.hexdigest(content)
    end

    # Embedding idempotency: reuse vectors already stored for identical content
    # produced by the SAME provider, and only call the embedder (spending quota)
    # for genuinely new text. Re-ingesting an unchanged document becomes a single
    # SELECT with zero embedding calls.
    def embed_with_reuse(pending, provider)
      hashes = pending.map { |chunk| chunk[:content_hash] }
      content_by_hash = pending.each_with_object({}) do |chunk, acc|
        acc[chunk[:content_hash]] ||= chunk[:content]
      end

      # One query for every reusable vector. select(...) (not pluck) so embedding
      # comes back as an Array<Float> via neighbor's attribute type, matching the
      # shape the embedder returns. First row per hash wins.
      cached = DocumentChunk
        .where(content_hash: content_by_hash.keys, embedding_provider: provider)
        .where.not(embedding: nil)
        .select(:content_hash, :embedding)
        .each_with_object({}) { |row, acc| acc[row.content_hash] ||= row.embedding }

      miss_hashes = content_by_hash.keys.reject { |hash| cached.key?(hash) }
      fresh = @embedder.embed(miss_hashes.map { |hash| content_by_hash[hash] })
      miss_hashes.each_with_index { |hash, i| cached[hash] = fresh[i] }

      hashes.map { |hash| cached[hash] }
    end
  end
end
