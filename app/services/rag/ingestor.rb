module Rag
  # Write Path orchestration: extract -> chunk -> embed (batched) -> persist.
  # Page numbers are preserved so the Read Path can cite exact sources.
  class Ingestor
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

        embeddings = Rag.tracer.in_span("rag.embed", attributes: { "rag.chunks.count" => pending.size }) do
          @embedder.embed(pending.map { |c| c[:content] })
        end
        pending.each_with_index { |chunk, i| chunk[:embedding] = embeddings[i] }

        # Bulk insert in a single statement instead of one INSERT per chunk: a
        # large document (100+ chunks) collapses from 100+ round-trips to one.
        # insert_all! skips validations/callbacks, so set timestamps explicitly.
        now = Time.current
        rows = pending.map do |chunk|
          { document_id: document.id, content: chunk[:content], page_number: chunk[:page_number],
            embedding: chunk[:embedding], created_at: now, updated_at: now }
        end

        # Delete via the model (not the association) so we don't load and cache
        # an empty target: insert_all! writes straight to SQL, which would leave
        # a stale in-memory association on the passed-in document.
        DocumentChunk.transaction do
          DocumentChunk.where(document_id: document.id).delete_all
          DocumentChunk.insert_all!(rows)
        end

        rows.size
      end
    end
  end
end
