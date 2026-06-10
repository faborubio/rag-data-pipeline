module Rag
  # Generates the natural-language answer from the retrieved context.
  # Uses OpenAI chat completions (guarded by a circuit breaker) when a key is
  # present; otherwise returns a deterministic, context-grounded answer so the
  # Read Path is fully testable without external calls.
  class Llm
    SYSTEM_PROMPT = <<~PROMPT.freeze
      Eres un asistente corporativo. Responde la pregunta del usuario usando
      EXCLUSIVAMENTE el contexto proporcionado. Cita la pagina cuando sea
      relevante. Si el contexto no contiene la respuesta, dilo claramente.
    PROMPT

    def initialize(api_key: ENV["OPENAI_API_KEY"], breaker: Rag.llm_breaker)
      @api_key = api_key
      @breaker = breaker
    end

    # question: String, contexts: Array<{content:, page_number:}> -> String
    def answer(question:, contexts:)
      if @api_key.present?
        @breaker.run { openai_answer(question, contexts) }
      else
        fallback_answer(question, contexts)
      end
    end

    # Streams the answer in deltas, yielding each text fragment to the block.
    # Returns the full answer string. Used by the SSE Read Path.
    def answer_stream(question:, contexts:, &block)
      if @api_key.present?
        @breaker.run { openai_answer_stream(question, contexts, &block) }
      else
        fallback_answer_stream(question, contexts, &block)
      end
    end

    private

    def openai_answer_stream(question, contexts, &block)
      client = OpenAI::Client.new(access_token: @api_key)
      full = +""
      client.chat(parameters: {
        model: Rag::CHAT_MODEL,
        temperature: 0.2,
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: user_prompt(question, contexts) }
        ],
        stream: proc do |chunk, _bytesize|
          delta = chunk.dig("choices", 0, "delta", "content")
          next if delta.nil?

          full << delta
          block.call(delta)
        end
      })
      full
    end

    def fallback_answer_stream(question, contexts, &block)
      text = fallback_answer(question, contexts)
      # Emit word-by-word to simulate token streaming.
      text.scan(/\S+\s*/).each { |fragment| block.call(fragment) }
      text
    end

    def openai_answer(question, contexts)
      client = OpenAI::Client.new(access_token: @api_key)
      response = client.chat(parameters: {
        model: Rag::CHAT_MODEL,
        temperature: 0.2,
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: user_prompt(question, contexts) }
        ]
      })
      response.dig("choices", 0, "message", "content").to_s.strip
    end

    def user_prompt(question, contexts)
      context_block = contexts.map { |c| "[pag. #{c[:page_number]}] #{c[:content]}" }.join("\n\n")
      "Contexto:\n#{context_block}\n\nPregunta: #{question}"
    end

    def fallback_answer(question, contexts)
      return "No se encontro contexto relevante para responder la pregunta." if contexts.empty?

      top = contexts.first
      "Segun la documentacion (pag. #{top[:page_number]}): #{top[:content]}"
    end
  end
end
