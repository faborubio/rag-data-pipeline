require "test_helper"

class Rag::IngestorTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "Acme")
    @document = @tenant.documents.create!(filename: "manual.pdf")
  end

  test "extracts, chunks, embeds and persists with page numbers" do
    path = build_pdf(Rails.root.join("tmp", "ingestor_test.pdf"), [
      "Primera pagina sobre seguridad e incendios.",
      "Segunda pagina sobre evacuacion y ascensores."
    ])

    count = Rag::Ingestor.new.call(@document, path)

    assert_operator count, :>=, 2
    assert_equal count, @document.document_chunks.count
    assert_equal [1, 2], @document.document_chunks.distinct.pluck(:page_number).sort
    assert_equal 1536, @document.document_chunks.first.embedding.size
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "re-ingesting replaces previous chunks" do
    path = build_pdf(Rails.root.join("tmp", "ingestor_reingest.pdf"), ["Una sola pagina."])
    Rag::Ingestor.new.call(@document, path)
    first_count = @document.document_chunks.count

    Rag::Ingestor.new.call(@document, path)
    assert_equal first_count, @document.document_chunks.count, "should not accumulate duplicates"
  ensure
    File.delete(path) if path && File.exist?(path)
  end
end
