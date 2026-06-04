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
      pages = @extractor.extract(file_path)

      pending = []
      pages.each do |page|
        @chunker.chunk(page[:text]).each do |content|
          pending << { content: content, page_number: page[:page] }
        end
      end

      return 0 if pending.empty?

      embeddings = @embedder.embed(pending.map { |c| c[:content] })
      pending.each_with_index { |chunk, i| chunk[:embedding] = embeddings[i] }

      DocumentChunk.transaction do
        document.document_chunks.delete_all
        pending.each { |attrs| document.document_chunks.create!(attrs) }
      end

      pending.size
    end
  end
end
