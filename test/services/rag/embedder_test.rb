require "test_helper"

class Rag::EmbedderTest < ActiveSupport::TestCase
  # Drives the Gemini path without hitting the network: `post_json` is fed by a
  # responder lambda, and `sleep` is captured instead of actually waiting.
  class StubbedEmbedder < Rag::Embedder
    attr_reader :sleeps

    def initialize(responder, **opts)
      super(gemini_key: "gk", breaker: Rag::CircuitBreaker.new(name: "test"), **opts)
      @responder = responder
      @sleeps = []
    end

    def sleep(seconds) = @sleeps << seconds
    def post_json(*args) = @responder.call(*args)
  end

  def gemini_body(payload)
    { "embeddings" => Array.new(payload[:requests].size) { { "values" => Array.new(1536, 0.01) } } }
  end
  test "produces one 1536-dim vector per input without an API key" do
    embedder = Rag::Embedder.new(api_key: nil, gemini_key: nil)
    vectors = embedder.embed(%w[a b c])

    assert_equal 3, vectors.size
    assert vectors.all? { |v| v.size == 1536 }
  end

  test "fallback embeddings are deterministic" do
    embedder = Rag::Embedder.new(api_key: nil, gemini_key: nil)
    assert_equal embedder.embed_one("hola"), embedder.embed_one("hola")
  end

  test "different texts yield different embeddings" do
    embedder = Rag::Embedder.new(api_key: nil, gemini_key: nil)
    refute_equal embedder.embed_one("hola"), embedder.embed_one("mundo")
  end

  test "live? reflects presence of any provider key" do
    assert_not Rag::Embedder.new(api_key: nil, gemini_key: nil).live?
    assert Rag::Embedder.new(api_key: "sk-test", gemini_key: nil).live?
    assert Rag::Embedder.new(api_key: nil, gemini_key: "gk-test").live?
  end

  test "provider prefers Gemini, then OpenAI, then the deterministic fallback" do
    assert_equal :gemini, Rag::Embedder.new(gemini_key: "gk", api_key: "sk").provider
    assert_equal :openai, Rag::Embedder.new(gemini_key: nil, api_key: "sk").provider
    assert_equal :fallback, Rag::Embedder.new(gemini_key: nil, api_key: nil).provider
  end

  test "handles batches larger than the batch size" do
    embedder = Rag::Embedder.new(api_key: nil, gemini_key: nil)
    inputs = Array.new(45) { |i| "text-#{i}" }
    assert_equal 45, embedder.embed(inputs).size
  end

  test "lexically similar texts are closer than disjoint ones" do
    embedder = Rag::Embedder.new(api_key: nil, gemini_key: nil)
    fire = embedder.embed_one("protocolo de incendio y evacuacion")
    fire_question = embedder.embed_one("que hacer ante un incendio")
    unrelated = embedder.embed_one("politica vacaciones empleados nuevos")

    assert_operator cosine(fire, fire_question), :>, cosine(fire, unrelated),
      "shared tokens should yield higher cosine similarity"
  end

  test "fallback is invariant to case, accents and punctuation" do
    embedder = Rag::Embedder.new(api_key: nil, gemini_key: nil)
    assert_equal embedder.embed_one("¿Incendio?"), embedder.embed_one("incendio")
    assert_equal embedder.embed_one("Evacuación"), embedder.embed_one("evacuacion")
  end

  test "token-less input yields a valid unit vector, not the zero vector" do
    embedder = Rag::Embedder.new(api_key: nil, gemini_key: nil)
    vector = embedder.embed_one("¡¿?!")

    assert_equal 1536, vector.size
    assert_in_delta 1.0, Math.sqrt(vector.sum { |x| x * x }), 1e-9
  end

  test "retries a rate-limited Gemini batch and then succeeds" do
    calls = 0
    responder = lambda do |_url, _headers, payload|
      calls += 1
      raise Rag::Embedder::RateLimitError, "429" if calls == 1

      gemini_body(payload)
    end
    embedder = StubbedEmbedder.new(responder, throttle: 0)

    vectors = embedder.embed([ "hola" ])

    assert_equal 1, vectors.size
    assert_equal 1536, vectors.first.size
    assert_equal 2, calls, "should retry once after the 429"
    assert_equal 1, embedder.sleeps.size, "should back off once before retrying"
  end

  test "gives up after exhausting retries on persistent rate limiting" do
    responder = ->(*_) { raise Rag::Embedder::RateLimitError, "429" }
    embedder = StubbedEmbedder.new(responder, throttle: 0)

    assert_raises(Rag::Embedder::RateLimitError) { embedder.embed([ "hola" ]) }
    assert_equal Rag::Embedder::MAX_RATE_LIMIT_RETRIES, embedder.sleeps.size
  end

  test "throttles between Gemini batches but never before the first" do
    responder = ->(_url, _headers, payload) { gemini_body(payload) }
    embedder = StubbedEmbedder.new(responder, throttle: 0.25)

    embedder.embed(Array.new(45) { |i| "t#{i}" }) # 45 inputs -> batches of 20, 20, 5

    assert_equal [ 0.25, 0.25 ], embedder.sleeps, "two gaps between three batches, none before the first"
  end

  private

  def cosine(a, b)
    a.zip(b).sum { |x, y| x * y }
  end
end
