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

      payload = Rails.cache.fetch(cache_key(tenant, question, document_ids), expires_in: 1.hour) do
        retrieve_and_generate(tenant, question, document_ids)
      end

      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      Result.new(answer: payload[:answer], sources: payload[:sources], latency_ms: latency_ms)
    end

    private

    def retrieve_and_generate(tenant, question, document_ids)
      query_vector = @embedder.embed_one(question)

      # Strict tenant isolation + restriction to the allowed document_ids.
      chunks = DocumentChunk
               .for_tenant(tenant)
               .where(document_id: document_ids)
               .nearest_neighbors(:embedding, query_vector, distance: "cosine")
               .limit(TOP_K)

      contexts = chunks.map do |chunk|
        { content: chunk.content, page_number: chunk.page_number, document_id: chunk.document_id }
      end

      answer = @llm.answer(question: question, contexts: contexts)
      sources = contexts.map do |c|
        { document_id: c[:document_id], page: c[:page_number], text_snippet: snippet(c[:content]) }
      end

      { answer: answer, sources: sources }
    end

    def snippet(text, length: 160)
      text = text.to_s
      text.length > length ? "#{text[0, length]}..." : text
    end

    def cache_key(tenant, question, document_ids)
      digest = Digest::SHA256.hexdigest([question, Array(document_ids).map(&:to_s).sort].to_json)
      "rag:query:#{tenant.id}:#{digest}"
    end
  end
end
