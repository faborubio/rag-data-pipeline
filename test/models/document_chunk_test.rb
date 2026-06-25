require "test_helper"

class DocumentChunkTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "Acme")
    @document = @tenant.documents.create!(filename: "a.pdf")
  end

  test "requires content and belongs to a document" do
    chunk = DocumentChunk.new(document: @document, content: nil)
    assert_not chunk.valid?
    assert_includes chunk.errors[:content], "can't be blank"
  end

  test "persists an EMBEDDING_DIMENSIONS-sized embedding" do
    chunk = @document.document_chunks.create!(content: "hola", embedding: sample_vector, page_number: 1)
    assert_equal Rag::EMBEDDING_DIMENSIONS, chunk.reload.embedding.size
  end

  test "nearest_neighbors orders by cosine distance" do
    v1 = Array.new(Rag::EMBEDDING_DIMENSIONS, 0.0); v1[0] = 1.0
    v2 = Array.new(Rag::EMBEDDING_DIMENSIONS, 0.0); v2[1] = 1.0
    near = @document.document_chunks.create!(content: "cercano", embedding: v1, page_number: 1)
    @document.document_chunks.create!(content: "lejano", embedding: v2, page_number: 2)

    query = Array.new(Rag::EMBEDDING_DIMENSIONS, 0.0); query[0] = 0.9
    results = DocumentChunk.nearest_neighbors(:embedding, query, distance: "cosine")
    assert_equal near, results.first
  end

  test "for_tenant scope isolates chunks by tenant" do
    @document.document_chunks.create!(content: "mio", embedding: sample_vector, page_number: 1)
    other_tenant = Tenant.create!(name: "Otra")

    assert_equal 1, DocumentChunk.for_tenant(@tenant).count
    assert_equal 0, DocumentChunk.for_tenant(other_tenant).count
  end

  test "full_text_search matches Spanish content and ignores accents" do
    fire = @document.document_chunks.create!(
      content: "Protocolo de incendio: evacuar por las escaleras.", embedding: sample_vector(1), page_number: 1
    )
    @document.document_chunks.create!(
      content: "Las contrasenas rotan cada 90 dias.", embedding: sample_vector(2), page_number: 2
    )

    # Query carries an accent the stored text lacks; immutable_unaccent bridges it.
    results = DocumentChunk.full_text_search("incendió")
    assert_equal [ fire ], results.to_a
  end

  test "full_text_search tolerates arbitrary user input without raising" do
    @document.document_chunks.create!(content: "algo", embedding: sample_vector(3), page_number: 1)
    assert_nothing_raised do
      DocumentChunk.full_text_search('"unbalanced & | : ( quote').to_a
    end
  end
end
