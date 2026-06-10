require "test_helper"

class Rag::SemanticChunkerTest < ActiveSupport::TestCase
  test "splits long text into multiple non-empty chunks" do
    chunker = Rag::SemanticChunker.new(chunk_size: 50, chunk_overlap: 10)
    chunks = chunker.chunk("palabra " * 100)

    assert_operator chunks.size, :>, 1
    assert chunks.all? { |c| c.is_a?(String) && !c.strip.empty? }
  end

  test "returns an empty array for blank input" do
    assert_equal [], Rag::SemanticChunker.new.chunk("")
    assert_equal [], Rag::SemanticChunker.new.chunk("   ")
    assert_equal [], Rag::SemanticChunker.new.chunk(nil)
  end

  test "keeps short text as a single chunk" do
    chunks = Rag::SemanticChunker.new(chunk_size: 500, chunk_overlap: 50).chunk("texto corto")
    assert_equal 1, chunks.size
  end
end
