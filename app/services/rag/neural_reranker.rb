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
      # True once a rerank has fallen back to the lexical reranker (model failed
      # to load/run). The scores then come from the lexical signal, which is NOT
      # comparable to MIN_RELEVANT_SCORE — see #confident?.
      @degraded = false
    end

    # candidates: Array of DocumentChunk (responds to #content). Returns
    # [ [chunk, score], ... ] reordered best-first by cross-encoder relevance.
    def rerank(question:, candidates:)
      return [] if candidates.empty?

      ranked = cross_encode(question, candidates.map(&:content))
      @degraded = false
      ranked.map { |row| [ candidates[row[:doc_id]], row[:score].to_f ] }
    rescue StandardError => e
      Rails.logger.warn("[NeuralReranker] falling back to lexical: #{e.class}: #{e.message}")
      @degraded = true
      @lexical.rerank(question: question, candidates: candidates)
    end

    # A low top cross-encoder score means the question is off-topic → gate it.
    # BUT when we've fallen back to the lexical reranker, `top_score` is a lexical
    # coverage score (0..~1.25), not a cross-encoder score — comparing it to 0.18
    # would misfire (false abstentions on semantic matches, off-topic answers on
    # stopword overlap). So in degraded mode defer to the lexical contract (never
    # gate): better to answer than to abstain on everything while the model is down.
    def confident?(top_score)
      return @lexical.confident?(top_score) if @degraded

      top_score >= MIN_RELEVANT_SCORE
    end

    # Loaded once per process — the model is ~230MB and slow to initialize.
    def self.pipeline
      @pipeline ||= Informers.pipeline("reranking", MODEL, quantized: true)
    end

    private

    # Seam over the memoized class-level pipeline, so tests can drive the
    # degraded fallback path without loading the ONNX model.
    def cross_encode(question, contents)
      self.class.pipeline.call(question, contents)
    end
  end
end
