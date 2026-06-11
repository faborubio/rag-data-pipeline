require "digest"

module Rag
  # Turns texts into 1536-dim embeddings. Uses OpenAI (text-embedding-3-small)
  # in batches of 20 to minimize network calls (spec), guarded by a circuit
  # breaker. With no OPENAI_API_KEY it returns deterministic pseudo-embeddings
  # so the whole pipeline runs locally without external dependencies.
  class Embedder
    BATCH_SIZE = 20

    def initialize(api_key: ENV["OPENAI_API_KEY"], breaker: Rag.embedding_breaker)
      @api_key = api_key
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
      @api_key.present?
    end

    private

    def embed_batch(batch)
      if live?
        @breaker.run { openai_embeddings(batch) }
      else
        batch.map { |text| fake_embedding(text) }
      end
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
