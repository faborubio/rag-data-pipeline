require "test_helper"

class Rag::LlmTest < ActiveSupport::TestCase
  test "fallback answer is grounded and cites the source inline" do
    answer = Rag::Llm.new(api_key: nil).answer(
      question: "¿Qué hago en caso de incendio?",
      contexts: [ { content: "evacuar por las escaleras", page_number: 12 } ]
    )

    assert_includes answer, "[1]", "should cite the source inline"
    assert_includes answer, "evacuar"
  end

  test "handles empty context gracefully" do
    answer = Rag::Llm.new(api_key: nil).answer(question: "x", contexts: [])
    assert answer.present?
  end

  test "extracts the relevant sentence and drops heading noise" do
    answer = Rag::Llm.new(api_key: nil).answer(
      question: "¿cuántas semanas dura la licencia parental?",
      contexts: [ { content: "Capitulo 6. Licencia parental. La licencia parental es de 12 semanas pagadas.", page_number: 6 } ]
    )

    assert_includes answer, "12 semanas"
    assert_not_includes answer, "Capitulo 6"
  end

  test "combines two sources that each cover query terms" do
    answer = Rag::Llm.new(api_key: nil).answer(
      question: "¿horario de respaldos y retención?",
      contexts: [
        { content: "Los respaldos se ejecutan cada noche a las 2 am.", page_number: 3 },
        { content: "La retención de respaldos es de 30 dias.", page_number: 4 }
      ]
    )

    assert_includes answer, "[1]"
    assert_includes answer, "[2]"
  end

  test "falls back to the full chunk for a purely semantic match" do
    # Query words never appear in the text (maternidad vs licencia parental).
    answer = Rag::Llm.new(api_key: nil).answer(
      question: "¿baja por maternidad?",
      contexts: [ { content: "Licencia parental de 12 semanas pagadas.", page_number: 6 } ]
    )

    assert_includes answer, "12 semanas"
    assert_includes answer, "[1]"
  end
end
