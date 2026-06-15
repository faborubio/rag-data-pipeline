module Rag
  # Deterministic lexical reranker (the resilient fallback for NeuralReranker).
  # Re-scores each (question, passage) pair by how much of the question's
  # content it actually covers — a signal RRF underweights — and reorders the
  # fused candidates. Stable: when nothing covers the question (a purely
  # semantic case), every score ties at 0 and the original fused order is kept,
  # so reranking never regresses retrieval.
  class Reranker
    BIGRAM_WEIGHT = 0.25

    # candidates: Array of DocumentChunk (responds to #content). Returns the same
    # objects, reordered best-first.
    def rerank(question:, candidates:)
      query = tokenize(question)
      return candidates if query.empty?

      query_set = query.to_set
      query_bigrams = query.each_cons(2).to_a

      candidates.each_with_index
                .sort_by { |chunk, i| [ -score(chunk, query_set, query_bigrams), i ] }
                .map(&:first)
    end

    private

    def score(chunk, query_set, query_bigrams)
      tokens = tokenize(chunk.content)
      return 0.0 if tokens.empty?

      token_set = tokens.to_set
      coverage = (query_set & token_set).size.fdiv(query_set.size)

      passage_bigrams = tokens.each_cons(2).to_set
      bigram_hits = query_bigrams.count { |bg| passage_bigrams.include?(bg) }
      bigram_bonus = query_bigrams.empty? ? 0.0 : bigram_hits.fdiv(query_bigrams.size)

      coverage + BIGRAM_WEIGHT * bigram_bonus
    end

    # Lowercase, accent-stripped word tokens (consistent with Embedder#tokenize).
    def tokenize(text)
      text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.scan(/[a-z0-9]+/)
    end
  end
end
