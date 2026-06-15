module Rag
  # Cross-encoder reranker: scores each (question, passage) pair jointly with a
  # local ONNX model (no API), so it catches semantic matches that share no
  # words with the query. Falls back to the lexical Reranker if the model can't
  # load (missing/corrupt download, OOM), so the Read Path degrades instead of
  # breaking.
  class NeuralReranker
    # Multilingual cross-encoder (XLM-R based): understands Spanish synonyms the
    # English model missed, so it complements the (also multilingual) Gemini
    # embeddings instead of demoting their hits.
    MODEL = "jinaai/jina-reranker-v2-base-multilingual".freeze

    # Below this top cross-encoder score, nothing in the corpus is actually
    # relevant to the question, so the Read Path abstains instead of inventing an
    # answer. Measured on a real corpus (in-scope >= ~0.20, off-topic <= ~0.15,
    # incl. tricky lexical collisions like "mundial"); tune with RERANK_MIN_SCORE.
    MIN_RELEVANT_SCORE = (ENV["RERANK_MIN_SCORE"] || 0.18).to_f

    def initialize(lexical: Reranker.new)
      @lexical = lexical
    end

    # candidates: Array of DocumentChunk (responds to #content). Returns
    # [ [chunk, score], ... ] reordered best-first by cross-encoder relevance.
    def rerank(question:, candidates:)
      return [] if candidates.empty?

      ranked = self.class.pipeline.call(question, candidates.map(&:content))
      ranked.map { |row| [ candidates[row[:doc_id]], row[:score].to_f ] }
    rescue StandardError => e
      Rails.logger.warn("[NeuralReranker] falling back to lexical: #{e.class}: #{e.message}")
      @lexical.rerank(question: question, candidates: candidates)
    end

    # A low top score means the question is off-topic for this corpus → gate it.
    def confident?(top_score) = top_score >= MIN_RELEVANT_SCORE

    # Loaded once per process — the model is ~230MB and slow to initialize.
    def self.pipeline
      @pipeline ||= Informers.pipeline("reranking", MODEL, quantized: true)
    end
  end
end
