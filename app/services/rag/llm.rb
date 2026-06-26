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

    # Deterministic extractive answer (no LLM): instead of dumping the whole top
    # chunk, surface the sentence(s) most relevant to the question — dropping
    # heading/boilerplate noise — and draw on up to two sources when both cover
    # query terms. Falls back to the full top chunk for purely semantic matches
    # (where the question's words never appear in the retrieved text).
    def fallback_answer(question, contexts)
      return "No se encontró contexto relevante para responder la pregunta." if contexts.empty?

      # Inline citations: each excerpt is tagged with [n], where n is the source's
      # 1-based position in the returned sources list, so every claim is traceable.
      query = tokenize(question).to_set
      excerpts = contexts.each_with_index.filter_map do |ctx, i|
        sentence = best_overlapping_sentence(ctx[:content], query)
        "#{sentence} [#{i + 1}]" if sentence
      end.first(2)

      return "Según la documentación: #{excerpts.join(' ')}" if excerpts.any?

      "Según la documentación: #{contexts.first[:content].strip} [1]"
    end

    # The chunk's sentence with the most query-term overlap; nil if none overlap.
    # Ties (e.g. a short heading vs the full informative sentence that share one
    # query word) break toward the longer, more informative sentence.
    def best_overlapping_sentence(content, query)
      sentence, score = split_sentences(content)
                        .map { |s| [ s, (tokenize(s).to_set & query).size ] }
                        .max_by { |(s, overlap)| [ overlap, s.length ] }
      score.to_i.zero? ? nil : sentence.strip
    end

    # Longest excerpt we'll treat as a single "sentence". Beyond this we window
    # the text so a chunk with no sentence punctuation (tables, bullet lists, OCR)
    # doesn't dump the whole 500-char block as the answer.
    SENTENCE_MAX = 280

    def split_sentences(text)
      text.to_s.strip
          .split(/(?<=[.!?])\s+|\n+/)
          .flat_map { |s| s.length > SENTENCE_MAX ? window(s) : s }
          .map(&:strip).reject(&:empty?)
    end

    # Break an over-long, punctuation-free run into bounded pieces, preferring a
    # whitespace boundary but always making progress (so it terminates).
    def window(text, size: SENTENCE_MAX)
      pieces = []
      rest = text.strip
      until rest.empty?
        if rest.length <= size
          pieces << rest
          break
        end
        cut = rest.rindex(/\s/, size) || size
        cut = size if cut.zero?
        pieces << rest[0...cut]
        rest = rest[cut..].to_s.lstrip
      end
      pieces
    end

    def tokenize(text)
      text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.scan(/[a-z0-9]+/)
    end
  end
end
