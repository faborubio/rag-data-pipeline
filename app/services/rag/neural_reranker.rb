module Rag
  # Cross-encoder reranker: scores each (question, passage) pair jointly with a
  # local ONNX model (no API), so it catches semantic matches that share no
  # words with the query. Falls back to the lexical Reranker if the model can't
  # load (missing/corrupt download, OOM), so the Read Path degrades instead of
  # breaking.
  class NeuralReranker
    # English-trained cross-encoder; cross-lingual transfer ranks the Spanish
    # corpus well. Quantized (int8) keeps the image/RAM footprint ~230MB.
    MODEL = "mixedbread-ai/mxbai-rerank-base-v1".freeze

    def initialize(lexical: Reranker.new)
      @lexical = lexical
    end

    # candidates: Array of DocumentChunk (responds to #content). Returns the same
    # objects reordered best-first by cross-encoder relevance.
    def rerank(question:, candidates:)
      return candidates if candidates.empty?

      ranked = self.class.pipeline.call(question, candidates.map(&:content))
      ranked.map { |row| candidates[row[:doc_id]] }
    rescue StandardError => e
      Rails.logger.warn("[NeuralReranker] falling back to lexical: #{e.class}: #{e.message}")
      @lexical.rerank(question: question, candidates: candidates)
    end

    # Loaded once per process — the model is ~230MB and slow to initialize.
    def self.pipeline
      @pipeline ||= Informers.pipeline("reranking", MODEL, quantized: true)
    end
  end
end
