require "digest"
require "net/http"
require "json"

module Rag
  # Turns texts into Rag::EMBEDDING_DIMENSIONS-sized embeddings, in batches of 20
  # to minimize network calls (spec), guarded by a circuit breaker. Provider:
  # EMBEDDER=local (local ONNX, default) > Gemini > OpenAI > a deterministic
  # bag-of-words fallback, so the pipeline (and the CI evals) run locally with no
  # external dependency at all.
  class Embedder
    # Raised when a provider replies 429 (rate limit). Retried with backoff
    # instead of failing the whole ingest — the free tier limits requests per
    # minute, so a large document just needs pacing, not more quota.
    class RateLimitError < StandardError; end

    BATCH_SIZE = 20
    # Retry/backoff for 429s. The free tier rate-limits in a roughly per-minute
    # window, so retries are patient enough to outlast it: delays grow ~2, 4, 8,
    # 16, 32, 32s (+ jitter) for 6 tries (~90s cumulative). If the wall is harder
    # (a daily cap), the batch eventually raises and the run stops — but every
    # batch embedded so far is already cached, so re-running resumes.
    MAX_RATE_LIMIT_RETRIES = 6
    RATE_LIMIT_BASE_DELAY = 2.0
    RATE_LIMIT_MAX_DELAY = 32.0
    RATE_LIMIT_JITTER = 1.0
    # Persistent memo for computed embeddings (Solid Cache). Lives long enough to
    # resume a multi-day paced bulk embed, but bounded so these large vectors
    # don't crowd out the latency-critical query-answer cache in the shared store.
    EMBEDDING_CACHE_TTL = 7.days
    GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/" \
                      "#{Rag::GEMINI_EMBEDDING_MODEL}:batchEmbedContents".freeze

    def initialize(gemini_key: ENV["GEMINI_API_KEY"], api_key: ENV["OPENAI_API_KEY"],
                   local: ENV["EMBEDDER"] == "local",
                   breaker: Rag.embedding_breaker,
                   throttle: (ENV["GEMINI_THROTTLE_SECONDS"] || 5.0).to_f)
      @gemini_key = gemini_key.presence
      @api_key = api_key.presence
      @local = local
      @breaker = breaker
      @throttle = throttle
    end

    # texts: Array<String> -> Array<Array<Float>> (aligned by index)
    #
    # `kind` tags the inputs as :query or :passage so the local e5 model can apply
    # its asymmetric prefixes (a no-op for the other providers). Ingestion embeds
    # passages (the default); the Read Path embeds the question with kind: :query.
    #
    # Live providers go through a persistent embedding cache keyed by provider +
    # (prefixed) content, written batch-by-batch: a paced bulk embed that gets
    # interrupted (rate limit, crash) keeps its progress, so a re-run only embeds
    # what's left. Batches are spaced out to stay under the free-tier per-minute
    # limit; a single batch (e.g. one query) never waits. The deterministic
    # fallback is local and free, so it skips the cache and the pacing entirely.
    def embed(texts, kind: :passage)
      texts = Array(texts)
      return [] if texts.empty?

      prov = provider
      inputs = texts.map { |text| prepare_input(prov, kind, text) }
      return inputs.map { |text| fake_embedding(text) } if prov == :fallback

      keys = inputs.map { |text| cache_key(prov, text) }
      cached = Rails.cache.read_multi(*keys.uniq)
      result = Array.new(inputs.size)
      misses = []
      inputs.each_index do |i|
        hit = cached[keys[i]]
        hit ? result[i] = hit : misses << i
      end

      misses.each_slice(BATCH_SIZE).with_index do |index_batch, batch_no|
        throttle if batch_no.positive? && prov == :gemini
        vectors = embed_batch(index_batch.map { |i| inputs[i] })
        index_batch.each_with_index do |i, j|
          result[i] = vectors[j]
          Rails.cache.write(keys[i], vectors[j], expires_in: EMBEDDING_CACHE_TTL)
        end
      end
      result
    end

    def embed_one(text, kind: :passage)
      embed([ text ], kind: kind).first
    end

    def live?
      @gemini_key.present? || @api_key.present?
    end

    # Which backend a query will actually use — surfaced by the evals report.
    # EMBEDDER=local wins over the API keys: the local model replaces Gemini as
    # the embedding space (one space per column), free of any rate limit.
    def provider
      return :local if @local
      return :gemini if @gemini_key.present?
      return :openai if @api_key.present?

      :fallback
    end

    private

    def embed_batch(batch)
      case provider
      when :local  then local_embedder.embed(batch)
      when :gemini then @breaker.run { with_rate_limit_retry { gemini_embeddings(batch) } }
      when :openai then @breaker.run { with_rate_limit_retry { openai_embeddings(batch) } }
      else batch.map { |text| fake_embedding(text) }
      end
    end

    # Memoized local ONNX embedder (no network, no breaker, no rate limit).
    def local_embedder
      @local_embedder ||= LocalEmbedder.new
    end

    # Per-provider input prep. The local e5 model wants asymmetric prefixes
    # ("query: " / "passage: "); every other provider takes the text verbatim, so
    # this is a no-op for them (and keeps their cache keys unchanged).
    def prepare_input(prov, kind, text)
      return text unless prov == :local && LocalEmbedder::USES_E5_PREFIXES

      "#{kind == :query ? 'query' : 'passage'}: #{text}"
    end

    # Retries a rate-limited (429) call with exponential backoff + jitter. Only
    # 429 is retried; other errors propagate immediately. Runs INSIDE the circuit
    # breaker, so a batch that eventually succeeds counts as one success and a
    # batch that exhausts its retries counts as a single breaker failure.
    def with_rate_limit_retry
      attempt = 0
      begin
        yield
      rescue RateLimitError
        attempt += 1
        raise if attempt > MAX_RATE_LIMIT_RETRIES

        sleep(backoff_seconds(attempt))
        retry
      end
    end

    def backoff_seconds(attempt)
      delay = RATE_LIMIT_BASE_DELAY * (2**(attempt - 1)) + rand * RATE_LIMIT_JITTER
      [ delay, RATE_LIMIT_MAX_DELAY ].min
    end

    def throttle
      sleep(@throttle) if @throttle.positive?
    end

    # Provider is part of the key: vectors from different providers live in
    # different spaces and must never be served for one another.
    def cache_key(provider, text)
      "rag:emb:#{provider}:#{Digest::SHA256.hexdigest(text)}"
    end

    # One batched call to Gemini; outputDimensionality pins the result to
    # Rag::EMBEDDING_DIMENSIONS so it lands in the same vector space as the others.
    def gemini_embeddings(batch)
      requests = batch.map do |text|
        { model: "models/#{Rag::GEMINI_EMBEDDING_MODEL}",
          content: { parts: [ { text: text } ] },
          outputDimensionality: Rag::EMBEDDING_DIMENSIONS }
      end
      body = post_json(GEMINI_ENDPOINT, { "x-goog-api-key" => @gemini_key }, { requests: requests })
      body.fetch("embeddings").map { |row| normalize_l2(row.fetch("values")) }
    end

    def post_json(url, headers, payload)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 30
      request = Net::HTTP::Post.new(uri)
      headers.each { |k, v| request[k] = v }
      request["Content-Type"] = "application/json"
      request.body = payload.to_json
      response = http.request(request)
      code = response.code.to_i
      raise RateLimitError, "Gemini API 429: #{response.body.to_s[0, 200]}" if code == 429
      raise "Gemini API #{response.code}: #{response.body.to_s[0, 200]}" unless code == 200

      JSON.parse(response.body)
    end

    # One network call for up to BATCH_SIZE inputs.
    def openai_embeddings(batch)
      client = OpenAI::Client.new(access_token: @api_key)
      response = client.embeddings(parameters: { model: Rag::EMBEDDING_MODEL, input: batch })
      response.fetch("data").sort_by { |row| row["index"] }.map { |row| row.fetch("embedding") }
    end

    # Deterministic bag-of-words embedding via signed feature hashing: each
    # token lands in a SHA256-derived bucket with sign +/-1, so lexically
    # similar texts get high cosine similarity without any external API. This
    # makes local retrieval (and the CI quality evals) meaningful.
    def fake_embedding(text)
      tokens = tokenize(text)
      return single_bucket_vector(text) if tokens.empty?

      vector = Array.new(Rag::EMBEDDING_DIMENSIONS, 0.0)
      tokens.each do |token|
        digest = Digest::SHA256.digest(token)
        index = digest[0, 4].unpack1("N") % Rag::EMBEDDING_DIMENSIONS
        sign = digest.getbyte(4).odd? ? 1.0 : -1.0
        vector[index] += sign
      end
      normalize_l2(vector)
    end

    # Lowercase, accent-stripped word tokens, so "¿Incendio?" == "incendio".
    def tokenize(text)
      text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.scan(/[a-z0-9]+/)
    end

    # Token-less input (empty/punctuation-only): a deterministic unit vector
    # keyed on the raw text, never the zero vector.
    def single_bucket_vector(text)
      index = Digest::SHA256.digest(text.to_s)[0, 4].unpack1("N") % Rag::EMBEDDING_DIMENSIONS
      Array.new(Rag::EMBEDDING_DIMENSIONS, 0.0).tap { |v| v[index] = 1.0 }
    end

    def normalize_l2(vector)
      norm = Math.sqrt(vector.sum { |x| x * x })
      norm.zero? ? vector : vector.map { |x| x / norm }
    end
  end
end
