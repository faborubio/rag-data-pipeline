module Rag
  module Evals
    # Pure retrieval/answer quality metrics over QueryService payloads.
    # `sources` is the QueryService shape: [{ document_id:, page:, text_snippet: }].
    module Metrics
      module_function

      # 1-based rank of the first source matching the expected document AND one
      # of its expected pages; nil if none in the list.
      def relevant_rank(sources, document_id:, expected_pages:)
        index = sources.find_index do |source|
          source[:document_id] == document_id && expected_pages.include?(source[:page])
        end
        index && index + 1
      end

      # 1.0 if a relevant source appears within the top k, else 0.0.
      def recall_at_k(sources, document_id:, expected_pages:, k:)
        rank = relevant_rank(sources.first(k), document_id: document_id, expected_pages: expected_pages)
        rank ? 1.0 : 0.0
      end

      # 1/rank of the first relevant source; 0.0 on a miss.
      def reciprocal_rank(sources, document_id:, expected_pages:)
        rank = relevant_rank(sources, document_id: document_id, expected_pages: expected_pages)
        rank ? 1.0 / rank : 0.0
      end

      # Answer prefix/citation tokens not drawn from the corpus, so they
      # shouldn't count against grounding ("Según la documentación (pág. 3): ...").
      ANSWER_BOILERPLATE = %w[segun la documentacion pag pagina].freeze

      # Faithfulness guardrail: fraction of the answer's content tokens that
      # actually appear in the retrieved context. ~1.0 for extractive answers;
      # catches a future generative LLM inventing claims absent from the sources.
      def grounding(answer, contexts)
        answer_tokens = content_tokens(answer)
        return 1.0 if answer_tokens.empty?

        context_tokens = contexts.flat_map { |c| content_tokens(c[:content]) }.to_set
        answer_tokens.count { |token| context_tokens.include?(token) }.fdiv(answer_tokens.size)
      end

      # Substantive tokens only: drop boilerplate and 1-char noise (stray page
      # digits, single letters) so grounding reflects real content.
      def content_tokens(text)
        normalize(text).scan(/[a-z0-9]+/).reject { |t| t.length < 2 || ANSWER_BOILERPLATE.include?(t) }
      end

      # Fraction of expected keywords present in the answer, compared after
      # normalization so accents/case never cause false misses.
      def keyword_presence(answer, keywords)
        return 0.0 if keywords.empty?

        normalized_answer = normalize(answer)
        hits = keywords.count { |keyword| normalized_answer.include?(normalize(keyword)) }
        hits.fdiv(keywords.size)
      end

      # Lowercase + accent-stripped + collapsed whitespace, so neither accents
      # nor pdftotext line wrapping/padding cause false keyword misses.
      def normalize(text)
        text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/\s+/, " ")
      end
    end
  end
end
