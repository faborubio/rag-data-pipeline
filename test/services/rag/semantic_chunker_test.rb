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

  test "does not merge across a section heading" do
    text = <<~DOC
      Artículo 1. Incendios

      En caso de incendio use las escaleras y no el ascensor.

      Artículo 2. Evacuación

      Diríjase al punto de encuentro siguiendo las señales.
    DOC

    chunks = Rag::SemanticChunker.new(chunk_size: 500, chunk_overlap: 50).chunk(text)

    assert_equal 2, chunks.size, "each section should be its own chunk"
    assert chunks.any? { |c| c.include?("Artículo 1") && c.include?("escaleras") }
    assert chunks.any? { |c| c.include?("Artículo 2") && c.include?("punto de encuentro") }
    refute chunks.any? { |c| c.include?("escaleras") && c.include?("punto de encuentro") },
           "content from two sections must not land in the same chunk"
  end

  test "reflows a hard-wrapped paragraph into one piece without newlines" do
    text = "El usuario debe leer\ncuidadosamente todas\nlas instrucciones antes\nde continuar."

    chunks = Rag::SemanticChunker.new(chunk_size: 500, chunk_overlap: 50).chunk(text)

    assert_equal 1, chunks.size
    refute_includes chunks.first, "\n", "wrapped lines should be joined back into a paragraph"
    assert_includes chunks.first, "leer cuidadosamente"
  end
end
