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

  test "persists a 1536-dim embedding" do
    chunk = @document.document_chunks.create!(content: "hola", embedding: sample_vector, page_number: 1)
    assert_equal 1536, chunk.reload.embedding.size
  end

  test "nearest_neighbors orders by cosine distance" do
    v1 = Array.new(1536, 0.0); v1[0] = 1.0
    v2 = Array.new(1536, 0.0); v2[1] = 1.0
    near = @document.document_chunks.create!(content: "cercano", embedding: v1, page_number: 1)
    @document.document_chunks.create!(content: "lejano", embedding: v2, page_number: 2)

    query = Array.new(1536, 0.0); query[0] = 0.9
    results = DocumentChunk.nearest_neighbors(:embedding, query, distance: "cosine")
    assert_equal near, results.first
  end

  test "for_tenant scope isolates chunks by tenant" do
    @document.document_chunks.create!(content: "mio", embedding: sample_vector, page_number: 1)
    other_tenant = Tenant.create!(name: "Otra")

    assert_equal 1, DocumentChunk.for_tenant(@tenant).count
    assert_equal 0, DocumentChunk.for_tenant(other_tenant).count
  end
end
