class Current < ActiveSupport::CurrentAttributes
  attribute :tenant, :user, :request_id, :rag

  # Per-request bag of RAG observability metrics (embed_ms, search_ms,
  # cache_hit, latency_ms, ...). Merged into the structured request log.
  def rag
    super || self.rag = {}
  end
end
