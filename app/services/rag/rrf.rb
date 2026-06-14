module Rag
  # Reciprocal Rank Fusion: combines several ranked result lists into one,
  # scoring each item by sum(1 / (k + rank)) across the lists it appears in.
  # Rank-based (not score-based), so it fuses heterogeneous signals — cosine
  # distance and ts_rank — without needing to normalize their scales.
  module Rrf
    # Cormack et al. (2009) found k=60 robust across tasks; it damps the weight
    # of top ranks just enough that a strong hit in one list still wins.
    DEFAULT_K = 60

    # rankings: Array of ranked Arrays (best first). `id` extracts the fusion key
    # (defaults to the item itself). Returns items ordered by fused score desc,
    # deduplicated, keeping the first object seen for each id.
    def self.fuse(*rankings, k: DEFAULT_K, id: :itself)
      scores = Hash.new(0.0)
      seen = {}

      rankings.each do |ranking|
        ranking.each_with_index do |item, index|
          key = item.public_send(id)
          scores[key] += 1.0 / (k + index + 1)
          seen[key] ||= item
        end
      end

      # Stable tie-break on first-seen order keeps fusion deterministic.
      order = seen.keys.each_with_index.to_h
      seen.values.sort_by { |item| key = item.public_send(id); [ -scores.fetch(key), order.fetch(key) ] }
    end
  end
end
