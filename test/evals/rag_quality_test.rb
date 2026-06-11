require "test_helper"

# RAG quality gate: runs the golden set through the real pipeline and fails CI
# if retrieval/answer quality regresses below Rag::Evals::Runner::THRESHOLDS.
# The fallback tier is pinned explicitly so an exported OPENAI_API_KEY can
# never make `rails test` hit the network.
class RagQualityTest < ActiveSupport::TestCase
  THRESHOLDS = Rag::Evals::Runner::THRESHOLDS

  def self.report
    @report ||= Rag::Evals::Runner.new(
      query_service: Rag::QueryService.new(
        embedder: Rag::Embedder.new(api_key: nil),
        llm: Rag::Llm.new(api_key: nil)
      )
    ).run
  end

  def report = self.class.report

  test "retrieval recall@k meets the lexical baseline" do
    assert_operator report.recall_at_k, :>=, THRESHOLDS[:recall_at_k],
      "Recall@#{report.k} regressed. Missed: #{report.failures.select { |r| r.recall.zero? }.map(&:id).join(', ')}"
  end

  test "retrieval MRR meets the lexical baseline" do
    assert_operator report.mrr, :>=, THRESHOLDS[:mrr],
      "MRR regressed. Worst ranks: #{report.rows.sort_by { |r| r.rank || 99 }.last(3).map { |r| "#{r.id}=#{r.rank || 'miss'}" }.join(', ')}"
  end

  test "answers contain the expected keywords" do
    assert_operator report.keyword_presence, :>=, THRESHOLDS[:keyword_presence],
      "Keyword presence regressed. Failing: #{report.failures.select { |r| r.keyword_presence < 1.0 }.map(&:id).join(', ')}"
  end
end
