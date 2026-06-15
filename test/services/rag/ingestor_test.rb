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
    assert_equal [ 1, 2 ], @document.document_chunks.distinct.pluck(:page_number).sort
    assert_equal 1536, @document.document_chunks.first.embedding.size
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "ingests a plain-text (.md) file via the dispatched extractor" do
    path = Rails.root.join("tmp", "ingestor_md_#{SecureRandom.hex(4)}.md")
    File.write(path, "# Seguridad\n\nEn caso de incendio, evacuar por las escaleras.\n\nNo usar el ascensor.")

    count = Rag::Ingestor.new.call(@document, path.to_s)

    assert_operator count, :>=, 1
    assert_equal count, @document.document_chunks.count
    assert_equal 1536, @document.document_chunks.first.embedding.size
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "re-ingesting replaces previous chunks" do
    path = build_pdf(Rails.root.join("tmp", "ingestor_reingest.pdf"), [ "Una sola pagina." ])
    Rag::Ingestor.new.call(@document, path)
    first_count = @document.document_chunks.count

    Rag::Ingestor.new.call(@document, path)
    assert_equal first_count, @document.document_chunks.count, "should not accumulate duplicates"
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  # Counts how many texts actually hit the embedder while delegating the real
  # work, so we can assert idempotency without calling any external provider.
  class CountingEmbedder
    attr_reader :embedded_count

    def initialize(inner = Rag::Embedder.new)
      @inner = inner
      @embedded_count = 0
    end

    def embed(texts)
      @embedded_count += Array(texts).size
      @inner.embed(texts)
    end

    def provider = @inner.provider
  end

  test "re-ingesting unchanged content reuses embeddings and does not re-embed" do
    path = build_pdf(Rails.root.join("tmp", "ingestor_idempotent.pdf"), [
      "Primera pagina sobre incendios.",
      "Segunda pagina sobre evacuacion."
    ])

    first = CountingEmbedder.new
    Rag::Ingestor.new(embedder: first).call(@document, path)
    assert_operator first.embedded_count, :>, 0
    original = @document.document_chunks.order(:page_number, :content).pluck(:embedding)

    second = CountingEmbedder.new
    Rag::Ingestor.new(embedder: second).call(@document, path)
    assert_equal 0, second.embedded_count, "unchanged chunks must not be re-embedded"

    reused = @document.document_chunks.order(:page_number, :content).pluck(:embedding)
    assert_equal original, reused, "reused vectors must be identical to the originals"
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "changed content is re-embedded" do
    original_path = build_pdf(Rails.root.join("tmp", "ingestor_changed_a.pdf"), [ "Texto original." ])
    Rag::Ingestor.new.call(@document, original_path)

    changed_path = build_pdf(Rails.root.join("tmp", "ingestor_changed_b.pdf"), [ "Texto completamente distinto." ])
    counting = CountingEmbedder.new
    Rag::Ingestor.new(embedder: counting).call(@document, changed_path)

    assert_operator counting.embedded_count, :>, 0, "new text must be embedded"
  ensure
    [ original_path, changed_path ].each { |p| File.delete(p) if p && File.exist?(p) }
  end
end
