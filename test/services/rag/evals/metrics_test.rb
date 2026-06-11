require "test_helper"

class Rag::Evals::MetricsTest < ActiveSupport::TestCase
  DOC = "doc-1".freeze

  def sources(*pairs)
    pairs.map { |doc, page| { document_id: doc, page: page, text_snippet: "..." } }
  end

  test "relevant_rank finds the first matching doc+page (1-based)" do
    list = sources([ "other", 1 ], [ DOC, 9 ], [ DOC, 2 ])
    assert_equal 3, Rag::Evals::Metrics.relevant_rank(list, document_id: DOC, expected_pages: [ 2 ])
  end

  test "relevant_rank is nil when the right page never appears" do
    list = sources([ DOC, 9 ], [ "other", 2 ])
    assert_nil Rag::Evals::Metrics.relevant_rank(list, document_id: DOC, expected_pages: [ 2 ])
  end

  test "recall_at_k respects the cutoff" do
    list = sources([ "other", 1 ], [ "other", 2 ], [ DOC, 5 ])
    assert_equal 1.0, Rag::Evals::Metrics.recall_at_k(list, document_id: DOC, expected_pages: [ 5 ], k: 3)
    assert_equal 0.0, Rag::Evals::Metrics.recall_at_k(list, document_id: DOC, expected_pages: [ 5 ], k: 2)
  end

  test "reciprocal_rank is 1/rank and 0.0 on a miss" do
    hit = sources([ "other", 1 ], [ DOC, 5 ])
    miss = sources([ "other", 1 ])
    assert_in_delta 0.5, Rag::Evals::Metrics.reciprocal_rank(hit, document_id: DOC, expected_pages: [ 5 ])
    assert_equal 0.0, Rag::Evals::Metrics.reciprocal_rank(miss, document_id: DOC, expected_pages: [ 5 ])
  end

  test "keyword_presence is the fraction found, accent and case insensitive" do
    answer = "Según la documentación: evacue por las ESCALERAS de emergencia"
    assert_in_delta 0.5, Rag::Evals::Metrics.keyword_presence(answer, [ "escaleras", "alarma" ])
    assert_in_delta 1.0, Rag::Evals::Metrics.keyword_presence(answer, [ "documentacion", "según" ])
    assert_equal 0.0, Rag::Evals::Metrics.keyword_presence(answer, [])
  end
end
