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

        DocumentChunk.transaction do
          document.document_chunks.delete_all
          pending.each { |attrs| document.document_chunks.create!(attrs) }
        end

        pending.size
      end
    end
  end
end
