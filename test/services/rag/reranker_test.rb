require "test_helper"

class Rag::RerankerTest < ActiveSupport::TestCase
  # Lightweight stand-in: the reranker only needs #content.
  Chunk = Struct.new(:content)

  def chunk(text) = Chunk.new(text)

  # rerank now returns [ [chunk, score], ... ]; this helper pulls the chunks.
  def chunks_of(ranked) = ranked.map(&:first)

  test "promotes the candidate that covers more of the question" do
    candidates = [
      chunk("Las vacaciones se acumulan a 15 dias por ano trabajado."),
      chunk("El protocolo de incendio indica evacuar por las escaleras de emergencia.")
    ]
    ranked = Rag::Reranker.new.rerank(question: "¿qué hago en caso de incendio?", candidates: candidates)
    assert_equal candidates.last, ranked.first.first
    assert_operator ranked.first.last, :>, 0.0, "the top result should carry a positive score"
  end

  test "preserves fused order when nothing covers the question (no regression)" do
    # No lexical overlap with the query -> all scores tie at 0 -> stable order.
    candidates = [ chunk("licencia parental de 12 semanas"), chunk("respaldos cada noche") ]
    ranked = Rag::Reranker.new.rerank(question: "vacaciones", candidates: candidates)
    assert_equal candidates, chunks_of(ranked)
  end

  test "is accent and case insensitive" do
    candidates = [ chunk("temas administrativos varios"), chunk("Politica de EVACUACION del edificio") ]
    ranked = Rag::Reranker.new.rerank(question: "¿cómo es la evacuación?", candidates: candidates)
    assert_equal candidates.last, ranked.first.first
  end

  test "returns candidates unchanged for an empty question" do
    candidates = [ chunk("a"), chunk("b") ]
    assert_equal candidates, chunks_of(Rag::Reranker.new.rerank(question: "  ", candidates: candidates))
  end

  test "the lexical reranker never gates answering" do
    assert Rag::Reranker.new.confident?(0.0)
    assert Rag::Reranker.new.confident?(1.0)
  end

  test "the neural reranker gates below its relevance threshold" do
    t = Rag::NeuralReranker::MIN_RELEVANT_SCORE
    assert Rag::NeuralReranker.new.confident?(t + 0.05), "above threshold -> answer"
    assert_not Rag::NeuralReranker.new.confident?(t - 0.05), "below threshold -> abstain"
  end

  # Neural reranker whose model can't load/run: exercises the lexical fallback.
  class FailingNeuralReranker < Rag::NeuralReranker
    private

    def cross_encode(*) = raise "model unavailable"
  end

  test "falls back to lexical scores when the cross-encoder fails" do
    candidates = [
      chunk("Las vacaciones se acumulan a 15 dias por ano trabajado."),
      chunk("El protocolo de incendio indica evacuar por las escaleras de emergencia.")
    ]
    ranked = FailingNeuralReranker.new.rerank(question: "¿qué hago en caso de incendio?", candidates: candidates)
    assert_equal candidates.last, ranked.first.first, "lexical fallback still reorders by coverage"
  end

  test "does not gate on the lexical score after falling back (no false abstention)" do
    reranker = FailingNeuralReranker.new
    # A purely semantic match the lexical signal scores at 0 would be wrongly
    # abstained if we kept comparing to the 0.18 cross-encoder threshold.
    reranker.rerank(question: "licencia parental", candidates: [ chunk("vacaciones anuales") ])
    assert reranker.confident?(0.0), "degraded mode must defer to the lexical (never-gate) contract"
  end
end
