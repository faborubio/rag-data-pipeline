require "digest"

module Rag
  # Read Path: embed the question, cosine-search the tenant's allowed chunks,
  # build a grounded prompt and generate the answer. Identical queries are
  # served from Solid Cache to cut token costs (spec: Cache Semantica).
  class QueryService
    TOP_K = 5

    Result = Struct.new(:answer, :sources, :latency_ms, keyword_init: true)

    def initialize(embedder: Embedder.new, llm: Llm.new)
      @embedder = embedder
      @llm = llm
    end

    def call(tenant:, question:, document_ids:)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cache_hit = true

      payload = Rails.cache.fetch(cache_key(tenant, question, document_ids), expires_in: 1.hour) do
        cache_hit = false
        retrieve_and_generate(tenant, question, document_ids)
      end

      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      Current.rag.merge!(cache_hit: cache_hit, sources: payload[:sources].size, latency_ms: latency_ms)
      record_metrics(latency_ms, cache_hit)
      Result.new(answer: payload[:answer], sources: payload[:sources], latency_ms: latency_ms)
    end

    # Retrieval only (no generation): used by the streaming Read Path, which
    # generates the answer token-by-token after fetching the context.
    # Returns { contexts: [...], sources: [...] }.
    def retrieve(tenant:, question:, document_ids:)
      query_vector = measure(:embed_ms) { @embedder.embed_one(question) }

      # Strict tenant isolation + restriction to the allowed document_ids.
      chunks = measure(:search_ms) do
        DocumentChunk
          .for_tenant(tenant)
          .where(document_id: document_ids)
          .nearest_neighbors(:embedding, query_vector, distance: "cosine")
          .limit(TOP_K)
          .to_a
      end

      contexts = chunks.map do |chunk|
        { content: chunk.content, page_number: chunk.page_number, document_id: chunk.document_id }
      end
      sources = contexts.map do |c|
        { document_id: c[:document_id], page: c[:page_number], text_snippet: snippet(c[:content]) }
      end

      { contexts: contexts, sources: sources }
    end

    private

    def retrieve_and_generate(tenant, question, document_ids)
      retrieval = retrieve(tenant: tenant, question: question, document_ids: document_ids)
      answer = @llm.answer(question: question, contexts: retrieval[:contexts])
      { answer: answer, sources: retrieval[:sources] }
    end

    def record_metrics(latency_ms, cache_hit)
      AppMetrics::QUERIES.increment
      AppMetrics::QUERY_LATENCY.observe(latency_ms / 1000.0)
      AppMetrics::CACHE_LOOKUPS.increment(labels: { result: cache_hit ? "hit" : "miss" })
      AppMetrics::EMBED_LATENCY.observe(Current.rag[:embed_ms] / 1000.0) if Current.rag[:embed_ms]
      AppMetrics::SEARCH_LATENCY.observe(Current.rag[:search_ms] / 1000.0) if Current.rag[:search_ms]
    end

    # Times the block and records the elapsed milliseconds into the per-request
    # RAG metrics bag (surfaced in the structured request log).
    def measure(key)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      Current.rag[key] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(2)
      result
    end

    def snippet(text, length: 160)
      text = text.to_s
      text.length > length ? "#{text[0, length]}..." : text
    end

    def cache_key(tenant, question, document_ids)
      digest = Digest::SHA256.hexdigest([ question, Array(document_ids).map(&:to_s).sort ].to_json)
      "rag:query:#{tenant.id}:#{digest}"
    end
  end
end
