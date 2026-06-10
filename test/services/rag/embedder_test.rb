require "test_helper"

class Rag::EmbedderTest < ActiveSupport::TestCase
  test "produces one 1536-dim vector per input without an API key" do
    embedder = Rag::Embedder.new(api_key: nil)
    vectors = embedder.embed(%w[a b c])

    assert_equal 3, vectors.size
    assert vectors.all? { |v| v.size == 1536 }
  end

  test "fallback embeddings are deterministic" do
    embedder = Rag::Embedder.new(api_key: nil)
    assert_equal embedder.embed_one("hola"), embedder.embed_one("hola")
  end

  test "different texts yield different embeddings" do
    embedder = Rag::Embedder.new(api_key: nil)
    refute_equal embedder.embed_one("hola"), embedder.embed_one("mundo")
  end

  test "live? reflects API key presence" do
    assert_not Rag::Embedder.new(api_key: nil).live?
    assert Rag::Embedder.new(api_key: "sk-test").live?
  end

  test "handles batches larger than the batch size" do
    embedder = Rag::Embedder.new(api_key: nil)
    inputs = Array.new(45) { |i| "text-#{i}" }
    assert_equal 45, embedder.embed(inputs).size
  end
end
