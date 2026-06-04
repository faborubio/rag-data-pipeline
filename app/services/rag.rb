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
end
