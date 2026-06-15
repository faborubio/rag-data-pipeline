require "test_helper"

class Rag::QueryServiceTest < ActiveSupport::TestCase
  # Reranker stub with a fixed top score, to drive the confidence gate.
  class FixedScoreReranker
    def initialize(score) = (@score = score)
    def rerank(question:, candidates:) = candidates.map { |c| [ c, @score ] }
    def confident?(score) = score >= Rag::NeuralReranker::MIN_RELEVANT_SCORE
  end

  setup do
    @tenant = Tenant.create!(name: "Acme")
    @document = @tenant.documents.create!(filename: "manual.pdf", status: :completed)
    embedder = Rag::Embedder.new(api_key: nil)
    @document.document_chunks.create!(
      content: "Protocolo de incendio: evacuar por las escaleras.",
      page_number: 12, embedding: embedder.embed_one("Protocolo de incendio: evacuar por las escaleras.")
    )
    @document.document_chunks.create!(
      content: "Queda prohibido usar el ascensor.",
      page_number: 13, embedding: embedder.embed_one("Queda prohibido usar el ascensor.")
    )
  end

  test "returns answer, sources and latency" do
    result = Rag::QueryService.new(reranker: Rag::Reranker.new).call(tenant: @tenant, question: "¿incendio?", document_ids: [ @document.id ])

    assert result.answer.present?
    assert_operator result.sources.size, :>=, 1
    source = result.sources.first
    assert source.key?(:document_id)
    assert source.key?(:page)
    assert source.key?(:text_snippet)
    assert_kind_of Integer, result.latency_ms
  end

  test "abstains (no sources) when reranker confidence is below the threshold" do
    svc = Rag::QueryService.new(reranker: FixedScoreReranker.new(0.05))
    result = svc.call(tenant: @tenant, question: "¿cuál es la capital de Francia?", document_ids: [ @document.id ])

    assert_equal Rag::QueryService::NO_ANSWER, result.answer
    assert_empty result.sources, "must not cite irrelevant pages when abstaining"
  end

  test "answers normally when reranker confidence is above the threshold" do
    svc = Rag::QueryService.new(reranker: FixedScoreReranker.new(0.9))
    result = svc.call(tenant: @tenant, question: "¿incendio?", document_ids: [ @document.id ])

    refute_equal Rag::QueryService::NO_ANSWER, result.answer
    assert_operator result.sources.size, :>=, 1
  end

  test "the streaming path also abstains when confidence is low" do
    svc = Rag::QueryService.new(reranker: FixedScoreReranker.new(0.05))
    streamed = +""
    sources = svc.call_streaming(tenant: @tenant, question: "¿fotosíntesis?", document_ids: [ @document.id ]) { |d| streamed << d }

    assert_equal Rag::QueryService::NO_ANSWER, streamed
    assert_empty sources
  end

  test "enforces strict tenant isolation" do
    other = Tenant.create!(name: "Otra")
    result = Rag::QueryService.new(reranker: Rag::Reranker.new).call(tenant: other, question: "¿incendio?", document_ids: [ @document.id ])
    assert_empty result.sources
  end

  test "full-text rescues an exact-term chunk the embedding ranks lower" do
    # A chunk whose embedding is unrelated to the query (random vector) but whose
    # text contains the exact rare term. Pure vector search would bury it; the
    # lexical signal pulls it into the fused top-K.
    exact = @document.document_chunks.create!(
      content: "El formulario INC-01 se entrega al comite de seguridad.",
      page_number: 99, embedding: sample_vector(42)
    )
    result = Rag::QueryService.new(reranker: Rag::Reranker.new).call(
      tenant: @tenant, question: "INC-01", document_ids: [ @document.id ]
    )
    assert_includes result.sources.map { |s| s[:page] }, exact.page_number
  end

  test "never returns more than TOP_K results" do
    10.times { |i| @document.document_chunks.create!(content: "c#{i}", page_number: i, embedding: sample_vector(i)) }
    result = Rag::QueryService.new(reranker: Rag::Reranker.new).call(tenant: @tenant, question: "algo", document_ids: [ @document.id ])
    assert_operator result.sources.size, :<=, Rag::QueryService::TOP_K
  end

  test "records observability metrics for the query" do
    Current.reset
    Rag::QueryService.new(reranker: Rag::Reranker.new).call(tenant: @tenant, question: "incendio", document_ids: [ @document.id ])

    assert Current.rag.key?(:embed_ms),   "should record embedding latency"
    assert Current.rag.key?(:search_ms),  "should record vector search latency"
    assert Current.rag.key?(:latency_ms), "should record total latency"
    assert_includes [ true, false ], Current.rag[:cache_hit]
  ensure
    Current.reset
  end

  test "serves an identical query from the cache on the second call" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    Current.reset
    Rag::QueryService.new(reranker: Rag::Reranker.new).call(tenant: @tenant, question: "incendio", document_ids: [ @document.id ])
    assert_equal false, Current.rag[:cache_hit], "first call is a miss"

    Current.reset
    Rag::QueryService.new(reranker: Rag::Reranker.new).call(tenant: @tenant, question: "incendio", document_ids: [ @document.id ])
    assert_equal true, Current.rag[:cache_hit], "second identical call is a hit"
  ensure
    Rails.cache = original_cache
    Current.reset
  end

  test "trivial wording variants (case, punctuation, spaces) share a cache entry" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    svc = Rag::QueryService.new(reranker: Rag::Reranker.new)

    Current.reset
    svc.call(tenant: @tenant, question: "¿Incendio?", document_ids: [ @document.id ])
    assert_equal false, Current.rag[:cache_hit], "first call is a miss"

    Current.reset
    svc.call(tenant: @tenant, question: "  incendio ", document_ids: [ @document.id ])
    assert_equal true, Current.rag[:cache_hit], "a case/punctuation/space variant should hit"
  ensure
    Rails.cache = original_cache
    Current.reset
  end

  test "re-ingesting a document busts its cached answers" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    svc = Rag::QueryService.new(reranker: Rag::Reranker.new)

    Current.reset
    svc.call(tenant: @tenant, question: "incendio", document_ids: [ @document.id ])

    Current.reset
    svc.call(tenant: @tenant, question: "incendio", document_ids: [ @document.id ])
    assert_equal true, Current.rag[:cache_hit], "unchanged content stays cached"

    # Simulate a re-ingest: chunks are rebuilt with fresh timestamps.
    @document.document_chunks.update_all(updated_at: 1.minute.from_now)

    Current.reset
    svc.call(tenant: @tenant, question: "incendio", document_ids: [ @document.id ])
    assert_equal false, Current.rag[:cache_hit], "changed content must invalidate the cache"
  ensure
    Rails.cache = original_cache
    Current.reset
  end

  test "streaming path caches the answer and replays it on the second stream" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    svc = Rag::QueryService.new(reranker: Rag::Reranker.new)

    Current.reset
    first = +""
    sources = svc.call_streaming(tenant: @tenant, question: "incendio", document_ids: [ @document.id ]) { |d| first << d }
    assert_equal false, Current.rag[:cache_hit], "first stream is a miss"
    assert first.present?, "the answer should be streamed in deltas"
    assert_operator sources.size, :>=, 1

    Current.reset
    second = +""
    svc.call_streaming(tenant: @tenant, question: "incendio", document_ids: [ @document.id ]) { |d| second << d }
    assert_equal true, Current.rag[:cache_hit], "second stream is a hit"
    assert_equal first, second, "the replayed answer matches the original"
  ensure
    Rails.cache = original_cache
    Current.reset
  end

  test "streamed and non-streamed paths share the same cache entry" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    svc = Rag::QueryService.new(reranker: Rag::Reranker.new)

    streamed = +""
    svc.call_streaming(tenant: @tenant, question: "incendio", document_ids: [ @document.id ]) { |d| streamed << d }

    Current.reset
    result = svc.call(tenant: @tenant, question: "incendio", document_ids: [ @document.id ])
    assert_equal true, Current.rag[:cache_hit], "non-streaming call reuses the streamed entry"
    assert_equal streamed, result.answer
  ensure
    Rails.cache = original_cache
    Current.reset
  end
end
