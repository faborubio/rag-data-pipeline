module Rag
  # Local neural embedder: turns text into dense vectors with a quantized ONNX
  # sentence-transformer (via informers), so there's no API, no key, no rate
  # limit and no per-call cost — the same local-model pattern the NeuralReranker
  # already uses. Chosen over the Gemini free tier, whose per-minute/daily caps
  # made bulk-embedding a large corpus impractical (see docs/AUDIT.md). Measured on
  # the golden set: recall@5 / MRR = 1.0 (matches Gemini, beats the BoW fallback).
  #
  # Selected with EMBEDDER=local; the Embedder delegates a batch of texts here.
  class LocalEmbedder
    # Multilingual e5 (384-d), quantized ONNX. The Xenova mirror ships the ONNX
    # weights informers needs (the intfloat/* repos don't). Keep in sync with the
    # model pre-baked in the Dockerfile and with Rag::EMBEDDING_DIMENSIONS (384).
    MODEL = "Xenova/multilingual-e5-small".freeze
    DIMENSIONS = 384

    # e5 was trained with asymmetric prefixes: questions as "query: ..." and
    # documents as "passage: ...". Using them is what gives the measured recall;
    # the Embedder tags each input with its kind so we can prefix correctly here.
    USES_E5_PREFIXES = true

    # texts: Array<String> already tagged by kind (:query/:passage) upstream.
    # Returns Array<Array<Float>>, L2-normalized (cosine-ready), aligned by index.
    def embed(texts)
      return [] if texts.empty?

      out = self.class.pipeline.(texts)
      rows = texts.size == 1 ? [ out ] : out
      rows.map { |v| normalize_l2(Array(v).flatten) }
    end

    # Loaded once per process — the model is slow to initialize, fast to run.
    def self.pipeline
      @pipeline ||= Informers.pipeline("embedding", MODEL, quantized: true)
    end

    private

    def normalize_l2(vector)
      norm = Math.sqrt(vector.sum { |x| x * x })
      norm.zero? ? vector : vector.map { |x| x / norm }
    end
  end
end
