require "test_helper"

# Verifies the OpenTelemetry wiring: the SDK is configured and our custom
# `rag.*` spans are emitted (and nested) for a RAG query. Spans are captured by
# the in-memory exporter installed for the test environment (see
# config/initializers/opentelemetry.rb).
class TracingTest < ActiveSupport::TestCase
  setup do
    Tracing::TEST_EXPORTER.reset
    @tenant = Tenant.create!(name: "Acme")
    @document = @tenant.documents.create!(filename: "manual.pdf", status: :completed)
    embedder = Rag::Embedder.new(api_key: nil)
    @document.document_chunks.create!(
      content: "Protocolo de incendio: evacuar por las escaleras.",
      page_number: 12,
      embedding: embedder.embed_one("Protocolo de incendio: evacuar por las escaleras.")
    )
  end

  test "the OpenTelemetry SDK is configured (real tracer provider)" do
    assert_kind_of OpenTelemetry::SDK::Trace::TracerProvider, OpenTelemetry.tracer_provider
  end

  test "a RAG query emits the custom rag.* spans" do
    run_query
    names = finished_span_names

    assert_includes names, "rag.query"
    assert_includes names, "rag.embed"
    assert_includes names, "rag.search"
    assert_includes names, "rag.generate"
  end

  test "the rag.query span carries cache and source attributes" do
    run_query
    span = finished_spans.find { |s| s.name == "rag.query" }

    assert span, "expected a rag.query span"
    assert_equal false, span.attributes["rag.cache_hit"]
    assert_operator span.attributes["rag.sources.count"], :>=, 1
    assert_equal 1, span.attributes["rag.documents.count"]
  end

  test "rag.embed and rag.search are nested under rag.query (same trace)" do
    run_query
    query = finished_spans.find { |s| s.name == "rag.query" }
    embed = finished_spans.find { |s| s.name == "rag.embed" }

    assert_equal query.trace_id, embed.trace_id, "spans should share one trace"
    assert_equal query.span_id, embed.parent_span_id, "rag.embed should be a child of rag.query"
  end

  private

  def run_query
    Rag::QueryService.new.call(tenant: @tenant, question: "¿incendio?", document_ids: [ @document.id ])
    OpenTelemetry.tracer_provider.force_flush
  end

  def finished_spans
    Tracing::TEST_EXPORTER.finished_spans
  end

  def finished_span_names
    finished_spans.map(&:name)
  end
end
