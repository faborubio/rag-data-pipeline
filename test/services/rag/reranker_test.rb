require "test_helper"

class Rag::RerankerTest < ActiveSupport::TestCase
  # Lightweight stand-in: the reranker only needs #content.
  Chunk = Struct.new(:content)

  def chunk(text) = Chunk.new(text)

  test "promotes the candidate that covers more of the question" do
    candidates = [
      chunk("Las vacaciones se acumulan a 15 dias por ano trabajado."),
      chunk("El protocolo de incendio indica evacuar por las escaleras de emergencia.")
    ]
    ranked = Rag::Reranker.new.rerank(question: "¿qué hago en caso de incendio?", candidates: candidates)
    assert_equal candidates.last, ranked.first
  end

  test "preserves fused order when nothing covers the question (no regression)" do
    # No lexical overlap with the query -> all scores tie at 0 -> stable order.
    candidates = [ chunk("licencia parental de 12 semanas"), chunk("respaldos cada noche") ]
    ranked = Rag::Reranker.new.rerank(question: "vacaciones", candidates: candidates)
    assert_equal candidates, ranked
  end

  test "is accent and case insensitive" do
    candidates = [ chunk("temas administrativos varios"), chunk("Politica de EVACUACION del edificio") ]
    ranked = Rag::Reranker.new.rerank(question: "¿cómo es la evacuación?", candidates: candidates)
    assert_equal candidates.last, ranked.first
  end

  test "returns candidates unchanged for an empty question" do
    candidates = [ chunk("a"), chunk("b") ]
    assert_equal candidates, Rag::Reranker.new.rerank(question: "  ", candidates: candidates)
  end
end
