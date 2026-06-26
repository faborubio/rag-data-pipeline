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
    # Cache TTL. The key is content-versioned (see cache_key), so a cached answer
    # can never go stale — this is purely a memory knob to evict cold entries.
    # 12h favours hit rate for rarely-changing manuals; entries left behind by a
    # re-ingest age out on their own.
    CACHE_TTL = 12.hours
    # Folded into the cache key so a change to how answers are built (format,
    # citations, prompt) invalidates old entries instead of serving stale ones.
    # Bump this whenever the answer shape changes.
    CACHE_VERSION = "v2-citations".freeze
    # Returned instead of a generated answer when retrieval isn't confident the
    # corpus actually covers the question — abstaining beats inventing.
    NO_ANSWER = "No encontré información sobre eso en los documentos consultados.".freeze

    Result = Struct.new(:answer, :sources, :latency_ms, :query_id, keyword_init: true)

    # Exposed so the evals harness can ask whether the active reranker can gate
    # answering at all (the lexical one never abstains) and decide if the
    # abstention metric is enforceable for this run.
    attr_reader :reranker

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

        payload = Rails.cache.fetch(cache_key(tenant, question, document_ids), expires_in: CACHE_TTL) do
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
        log_query(tenant, question, payload, cache_hit, latency_ms)
        Result.new(answer: payload[:answer], sources: payload[:sources],
                   latency_ms: latency_ms, query_id: Current.rag[:query_id])
      end
    end

    # Streaming Read Path, sharing #call's cache (same key, same payload shape).
    # On a cache hit the stored answer is replayed in one delta — no embed,
    # search, rerank or LLM. On a miss the LLM is streamed token-by-token, the
    # text is accumulated and written to the cache at the end, so the next call
    # — streamed OR not — is a hit. Yields answer deltas; returns the sources.
    def call_streaming(tenant:, question:, document_ids:, &block)
      Rag.tracer.in_span("rag.query", attributes: {
        "rag.documents.count" => document_ids.size,
        "rag.question.length" => question.to_s.length,
        "rag.stream" => true
      }) do |span|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        key = cache_key(tenant, question, document_ids)
        payload = Rails.cache.read(key)
        cache_hit = !payload.nil?

        if cache_hit
          block.call(payload[:answer])
        else
          retrieval = retrieve(tenant: tenant, question: question, document_ids: document_ids)
          if retrieval[:confident]
            buffer = +""
            Rag.tracer.in_span("rag.generate") do
              @llm.answer_stream(question: question, contexts: retrieval[:contexts]) do |delta|
                buffer << delta
                block.call(delta)
              end
            end
            payload = { answer: buffer, sources: retrieval[:sources] }
          else
            # Off-topic for this corpus: abstain instead of inventing an answer.
            block.call(NO_ANSWER)
            payload = { answer: NO_ANSWER, sources: [] }
          end
          # Cache only a fully streamed answer; a client disconnect raises out of
          # the block above before we get here, so partial answers are never cached.
          Rails.cache.write(key, payload, expires_in: CACHE_TTL)
        end

        latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        Current.rag.merge!(cache_hit: cache_hit, sources: payload[:sources].size, latency_ms: latency_ms)
        record_metrics(latency_ms, cache_hit)
        span.add_attributes(
          "rag.cache_hit" => cache_hit,
          "rag.sources.count" => payload[:sources].size,
          "rag.latency_ms" => latency_ms
        )
        log_query(tenant, question, payload, cache_hit, latency_ms)
        payload[:sources]
      end
    end

    # Retrieval only (no generation): the building block for the streaming Read
    # Path, which generates the answer token-by-token after fetching the context.
    # Returns { contexts:, sources:, confident:, score: } — `confident` is false
    # when the top reranker score says nothing in the corpus is relevant.
    def retrieve(tenant:, question:, document_ids:)
      query_vector = measure(:embed_ms) do
        Rag.tracer.in_span("rag.embed") { @embedder.embed_one(question, kind: :query) }
      end

      # Hybrid retrieval: fuse dense (cosine) and lexical (full-text) candidates
      # with Reciprocal Rank Fusion. Vector search handles paraphrase/semantics;
      # full-text nails exact terms, codes and names the embedding may miss.
      top_score = 0.0
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

          # Second stage: a cross-encoder scores each (question, passage) pair and
          # reorders. The top score doubles as a relevance signal: too low and we
          # abstain instead of answering from irrelevant chunks.
          reranked = Rag.tracer.in_span("rag.rerank", attributes: { "rag.rerank.candidates" => fused.size }) do
            @reranker.rerank(question: question, candidates: fused)
          end
          top_score = reranked.first&.last.to_f
          rows = reranked.first(TOP_K).map(&:first)

          span.add_attributes(
            "rag.vector.count" => vector_hits.size,
            "rag.fulltext.count" => text_hits.size,
            "rag.chunks.count" => rows.size,
            "rag.rerank.top_score" => top_score
          )
          rows
        end
      end

      confident = @reranker.confident?(top_score)
      Current.rag.merge!(confident: confident, rerank_score: top_score)

      contexts = chunks.map do |chunk|
        { content: chunk.content, page_number: chunk.page_number, document_id: chunk.document_id }
      end
      sources = contexts.map do |c|
        { document_id: c[:document_id], page: c[:page_number], text_snippet: snippet(c[:content]) }
      end

      { contexts: contexts, sources: sources, confident: confident, score: top_score }
    end

    private

    def retrieve_and_generate(tenant, question, document_ids)
      retrieval = retrieve(tenant: tenant, question: question, document_ids: document_ids)
      return { answer: NO_ANSWER, sources: [] } unless retrieval[:confident]

      answer = Rag.tracer.in_span("rag.generate") do
        @llm.answer(question: question, contexts: retrieval[:contexts])
      end
      { answer: answer, sources: retrieval[:sources] }
    end

    # Append-only analytics row per query. Best-effort: analytics must never break
    # a query, so any failure is swallowed.
    def log_query(tenant, question, payload, cache_hit, latency_ms)
      log = QueryLog.create!(
        tenant: tenant,
        question: QueryLog.sanitize_question(question),
        answered: payload[:answer] != NO_ANSWER,
        rerank_score: Current.rag[:rerank_score],
        cache_hit: cache_hit,
        sources_count: payload[:sources].size,
        latency_ms: latency_ms
      )
      # Exposed so the response can carry it and the client can attach feedback.
      Current.rag[:query_id] = log.id
    rescue StandardError => e
      Rails.logger.warn("[Analytics] failed to log query: #{e.class}: #{e.message}")
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

    # Versioned cache key, scoped by tenant for isolation. The digest folds in:
    #   - a normalized question, so trivial wording variants (case, surrounding
    #     punctuation, extra whitespace) share one entry instead of redoing work;
    #   - the content version of the queried documents, so re-ingesting a document
    #     invalidates its cached answers instead of serving a stale one for the
    #     whole TTL.
    def cache_key(tenant, question, document_ids)
      ids = Array(document_ids).map(&:to_s).sort
      # Fall back to the raw (stripped/downcased) question when normalization
      # empties it (e.g. "???"), so degenerate punctuation-only questions don't
      # all collapse to one cache entry and serve each other's answers.
      key_question = normalize_question(question).presence || question.to_s.strip.downcase
      digest = Digest::SHA256.hexdigest(
        [ CACHE_VERSION, key_question, ids, documents_version(ids) ].to_json
      )
      "rag:query:#{tenant.id}:#{digest}"
    end

    # Safe normalization for more cache hits: downcase, collapse whitespace and
    # trim surrounding punctuation, so "¿Qué hago?" and "que hago" with trailing
    # spaces map to the same key. Deliberately does NOT strip accents — in Spanish
    # that can change meaning ("si"/"sí"), and a wrong cache hit is worse than a miss.
    def normalize_question(question)
      question.to_s.unicode_normalize(:nfc)
              .strip.downcase
              .gsub(/\s+/, " ")
              .gsub(/\A\p{P}+|\p{P}+\z/, "")
              .strip
    end

    # Content fingerprint of the queried documents: their latest chunk timestamp.
    # insert_all! stamps every chunk on each (re)ingest, so any rebuild bumps this
    # and busts the cache. One indexed aggregate (~1ms) — negligible vs a miss.
    def documents_version(document_ids)
      DocumentChunk.where(document_id: document_ids).maximum(:updated_at)&.to_f
    end
  end
end
