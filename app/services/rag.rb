# Namespace + shared, process-local circuit breakers for the external AI calls.
module Rag
  # 384 dims — the native size of the local ONNX embedder (LocalEmbedder, the
  # default provider). Every provider lands in this one space so a single
  # vector(384) column + HNSW index serves all of them: the BoW fallback builds
  # 384-d vectors, Gemini is asked for 384 via outputDimensionality, and OpenAI
  # via `dimensions`. Changing this requires a schema migration + re-embed.
  EMBEDDING_DIMENSIONS = 384
  EMBEDDING_MODEL = "text-embedding-3-small".freeze
  GEMINI_EMBEDDING_MODEL = "gemini-embedding-001".freeze
  CHAT_MODEL = "gpt-4o-mini".freeze

  # Accepted upload formats and the extractor each maps to.
  PDF_EXTENSIONS = %w[.pdf].freeze
  TEXT_EXTENSIONS = %w[.txt .md .markdown].freeze
  ACCEPTED_EXTENSIONS = (PDF_EXTENSIONS + TEXT_EXTENSIONS).freeze

  # Picks the extractor for a file by extension (Write Path is format-agnostic
  # past this point: chunk -> embed -> persist is identical for every format).
  def self.extractor_for(path)
    TEXT_EXTENSIONS.include?(File.extname(path).downcase) ? PlainTextExtractor.new : PdfTextExtractor.new
  end

  # Rate limits (429) are backpressure, not an outage, so they are ignored by the
  # breaker — otherwise a few throttled batches during a large ingest would trip
  # it and abort the whole document. The Embedder retries 429s with backoff.
  def self.embedding_breaker
    @embedding_breaker ||= CircuitBreaker.new(name: "embeddings", ignore: [ Embedder::RateLimitError ])
  end

  def self.llm_breaker
    @llm_breaker ||= CircuitBreaker.new(name: "openai_llm")
  end

  # Shared OpenTelemetry tracer for the custom `rag.*` spans. Returns a no-op
  # tracer if the SDK is not configured, so callers never need to guard.
  def self.tracer
    OpenTelemetry.tracer_provider.tracer("rag-data-pipeline")
  end

  # Reranker used by the Read Path. The deterministic lexical reranker is the
  # default: measured against real Gemini embeddings it preserves the strong
  # retrieval order (recall@5 1.0), whereas the English neural cross-encoder
  # demotes the one hard Spanish semantic match out of the top-5. The neural
  # cross-encoder stays available opt-in (RERANKER=neural) pending a
  # multilingual model. See docs/AUDIT.md.
  def self.reranker
    ENV["RERANKER"] == "neural" ? NeuralReranker.new : Reranker.new
  end
end
