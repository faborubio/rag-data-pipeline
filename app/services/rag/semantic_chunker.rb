module Rag
  # Recursive character/token text splitting (spec: RecursiveCharacterTextSplitter
  # via langchainrb, 500 max + 10% / 50 overlap). Falls back to a plain sliding
  # window if langchainrb/baran is unavailable or its API changes.
  class SemanticChunker
    CHUNK_SIZE = 500
    CHUNK_OVERLAP = 50

    def initialize(chunk_size: CHUNK_SIZE, chunk_overlap: CHUNK_OVERLAP)
      @chunk_size = chunk_size
      @chunk_overlap = chunk_overlap
    end

    # text -> Array<String>
    def chunk(text)
      return [] if text.nil? || text.strip.empty?

      langchain_chunks(text) || fallback_chunks(text)
    end

    private

    def langchain_chunks(text)
      return nil unless defined?(Langchain::Chunker::RecursiveText)

      Langchain::Chunker::RecursiveText
        .new(text, chunk_size: @chunk_size, chunk_overlap: @chunk_overlap)
        .chunks
        .map { |c| c.respond_to?(:text) ? c.text : c.to_s }
        .map(&:strip)
        .reject(&:empty?)
    rescue StandardError => e
      Rails.logger.warn("[SemanticChunker] langchainrb failed (#{e.class}: #{e.message}); using fallback")
      nil
    end

    def fallback_chunks(text)
      step = [@chunk_size - @chunk_overlap, 1].max
      chunks = []
      i = 0
      while i < text.length
        piece = text[i, @chunk_size].to_s.strip
        chunks << piece unless piece.empty?
        i += step
      end
      chunks
    end
  end
end
