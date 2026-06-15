require "digest"
require "net/http"
require "json"

module Rag
  # Turns texts into 1536-dim embeddings, in batches of 20 to minimize network
  # calls (spec), guarded by a circuit breaker. Provider is chosen by which key
  # is present: Gemini (free tier, gemini-embedding-001) > OpenAI > a
  # deterministic bag-of-words fallback so the pipeline (and the CI evals) run
  # locally with no external dependency at all.
  class Embedder
    BATCH_SIZE = 20
    GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/" \
                      "#{Rag::GEMINI_EMBEDDING_MODEL}:batchEmbedContents".freeze

    def initialize(gemini_key: ENV["GEMINI_API_KEY"], api_key: ENV["OPENAI_API_KEY"],
                   breaker: Rag.embedding_breaker)
      @gemini_key = gemini_key.presence
      @api_key = api_key.presence
      @breaker = breaker
    end

    # texts: Array<String> -> Array<Array<Float>> (aligned by index)
    def embed(texts)
      Array(texts).each_slice(BATCH_SIZE).flat_map { |batch| embed_batch(batch) }
    end

    def embed_one(text)
      embed([ text ]).first
    end

    def live?
      @gemini_key.present? || @api_key.present?
    end

    # Which backend a query will actually use — surfaced by the evals report.
    def provider
      return :gemini if @gemini_key.present?
      return :openai if @api_key.present?

      :fallback
    end

    private

    def embed_batch(batch)
      case provider
      when :gemini then @breaker.run { gemini_embeddings(batch) }
      when :openai then @breaker.run { openai_embeddings(batch) }
      else batch.map { |text| fake_embedding(text) }
      end
    end

    # One batched call to Gemini; outputDimensionality pins the result to 1536.
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
      raise "Gemini API #{response.code}: #{response.body.to_s[0, 200]}" unless response.code.to_i == 200

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
