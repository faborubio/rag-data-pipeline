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
