# Namespace + shared, process-local circuit breakers for the external AI calls.
module Rag
  # 1536 dims, OpenAI text-embedding-3-small (per spec).
  EMBEDDING_DIMENSIONS = 1536
  EMBEDDING_MODEL = "text-embedding-3-small".freeze
  CHAT_MODEL = "gpt-4o-mini".freeze

  def self.embedding_breaker
    @embedding_breaker ||= CircuitBreaker.new(name: "openai_embeddings")
  end

  def self.llm_breaker
    @llm_breaker ||= CircuitBreaker.new(name: "openai_llm")
  end

  # Shared OpenTelemetry tracer for the custom `rag.*` spans. Returns a no-op
  # tracer if the SDK is not configured, so callers never need to guard.
  def self.tracer
    OpenTelemetry.tracer_provider.tracer("rag-data-pipeline")
  end
end
