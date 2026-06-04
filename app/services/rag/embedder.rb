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
      embed([text]).first
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

    # Deterministic, L2-normalized vector derived from the text hash.
    def fake_embedding(text)
      seed = Digest::SHA256.hexdigest(text.to_s).to_i(16) % (2**31)
      rng = Random.new(seed)
      vector = Array.new(Rag::EMBEDDING_DIMENSIONS) { rng.rand(-1.0..1.0) }
      norm = Math.sqrt(vector.sum { |x| x * x })
      norm.zero? ? vector : vector.map { |x| x / norm }
    end
  end
end
