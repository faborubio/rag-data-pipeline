require "test_helper"

class Rag::LlmTest < ActiveSupport::TestCase
  test "fallback answer is grounded and cites the page" do
    answer = Rag::Llm.new(api_key: nil).answer(
      question: "¿Qué hago en caso de incendio?",
      contexts: [{ content: "evacuar por las escaleras", page_number: 12 }]
    )

    assert_includes answer, "12"
    assert_includes answer, "evacuar"
  end

  test "handles empty context gracefully" do
    answer = Rag::Llm.new(api_key: nil).answer(question: "x", contexts: [])
    assert answer.present?
  end
end
