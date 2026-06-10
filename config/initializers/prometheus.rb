require "prometheus/client"

# Lightweight application metrics, exposed in Prometheus text format at /metrics.
# (Single-process registry; for multi-worker Puma use a DirectFileStore.)
module AppMetrics
  REGISTRY = Prometheus::Client.registry

  def self.counter(name, docstring, labels = [])
    REGISTRY.exist?(name) ? REGISTRY.get(name) : REGISTRY.counter(name, docstring: docstring, labels: labels)
  end

  def self.histogram(name, docstring, labels = [])
    REGISTRY.exist?(name) ? REGISTRY.get(name) : REGISTRY.histogram(name, docstring: docstring, labels: labels)
  end

  QUERIES        = counter(:rag_queries_total, "Total RAG queries processed")
  QUERY_LATENCY  = histogram(:rag_query_latency_seconds, "RAG query total latency (seconds)")
  EMBED_LATENCY  = histogram(:rag_embed_latency_seconds, "Question embedding latency (seconds)")
  SEARCH_LATENCY = histogram(:rag_search_latency_seconds, "Vector search latency (seconds)")
  CACHE_LOOKUPS  = counter(:rag_cache_lookups_total, "Semantic cache lookups", [ :result ])
  INGESTIONS     = counter(:rag_ingestions_total, "Document ingestions", [ :status ])
end
