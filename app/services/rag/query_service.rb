require "digest"

module Rag
  # Read Path: embed the question, hybrid-search the tenant's allowed chunks,
  # build a grounded prompt and generate the answer. Identical queries (same
  # question + document set) are served from Solid Cache to cut token costs —
  # an exact-match cache; a true embedding-similarity cache is future work.
  class QueryService
    TOP_K = 5
    # Candidates pulled from each retriever before fusion. Wider than TOP_K so a
    # chunk ranked outside one signal's top-5 can still surface if the other
    # signal ranks it highly.
    CANDIDATE_POOL = 20
    # Fused candidates fed to the reranker. Bounded (< CANDIDATE_POOL) to cap the
    # cross-encoder's per-query cost on a single CPU.
    RERANK_CANDIDATES = 10

    Result = Struct.new(:answer, :sources, :latency_ms, keyword_init: true)

    def initialize(embedder: Embedder.new, llm: Llm.new, reranker: Rag.reranker)
      @embedder = embedder
      @llm = llm
      @reranker = reranker
    end

    def call(tenant:, question:, document_ids:)
      Rag.tracer.in_span("rag.query", attributes: {
        "rag.documents.count" => document_ids.size,
        "rag.question.length" => question.to_s.length
      }) do |span|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        cache_hit = true

        payload = Rails.cache.fetch(cache_key(tenant, question, document_ids), expires_in: 1.hour) do
          cache_hit = false
          retrieve_and_generate(tenant, question, document_ids)
        end

        latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        Current.rag.merge!(cache_hit: cache_hit, sources: payload[:sources].size, latency_ms: latency_ms)
        record_metrics(latency_ms, cache_hit)
        span.add_attributes(
          "rag.cache_hit" => cache_hit,
          "rag.sources.count" => payload[:sources].size,
          "rag.latency_ms" => latency_ms
        )
        Result.new(answer: payload[:answer], sources: payload[:sources], latency_ms: latency_ms)
      end
    end

    # Retrieval only (no generation): used by the streaming Read Path, which
    # generates the answer token-by-token after fetching the context.
    # Returns { contexts: [...], sources: [...] }.
    def retrieve(tenant:, question:, document_ids:)
      query_vector = measure(:embed_ms) do
        Rag.tracer.in_span("rag.embed") { @embedder.embed_one(question) }
      end

      # Hybrid retrieval: fuse dense (cosine) and lexical (full-text) candidates
      # with Reciprocal Rank Fusion. Vector search handles paraphrase/semantics;
      # full-text nails exact terms, codes and names the embedding may miss.
      chunks = measure(:search_ms) do
        Rag.tracer.in_span("rag.search", attributes: { "rag.top_k" => TOP_K }) do |span|
          scope = DocumentChunk.for_tenant(tenant).where(document_id: document_ids)

          vector_hits = Rag.tracer.in_span("rag.search.vector") do
            scope.nearest_neighbors(:embedding, query_vector, distance: "cosine")
                 .limit(CANDIDATE_POOL).to_a
          end
          text_hits = Rag.tracer.in_span("rag.search.fulltext") do
            scope.full_text_search(question).limit(CANDIDATE_POOL).to_a
          end

          fused = Rag::Rrf.fuse(vector_hits, text_hits, id: :id).first(RERANK_CANDIDATES)

          # Second stage: a cross-encoder reads each (question, passage) pair and
          # reorders, promoting the truly relevant chunk before we cut to TOP_K.
          reranked = Rag.tracer.in_span("rag.rerank", attributes: { "rag.rerank.candidates" => fused.size }) do
            @reranker.rerank(question: question, candidates: fused)
          end
          rows = reranked.first(TOP_K)

          span.add_attributes(
            "rag.vector.count" => vector_hits.size,
            "rag.fulltext.count" => text_hits.size,
            "rag.chunks.count" => rows.size
          )
          rows
        end
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
      answer = Rag.tracer.in_span("rag.generate") do
        @llm.answer(question: question, contexts: retrieval[:contexts])
      end
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
