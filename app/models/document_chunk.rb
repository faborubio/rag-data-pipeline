class DocumentChunk < ApplicationRecord
  # neighbor gem: enables cosine similarity search over the pgvector column,
  # e.g. DocumentChunk.nearest_neighbors(:embedding, query_vector, distance: "cosine")
  has_neighbors :embedding

  belongs_to :document

  validates :content, presence: true

  # Tenant isolation helper: only chunks belonging to the given tenant's documents.
  scope :for_tenant, ->(tenant) {
    joins(:document).where(documents: { tenant_id: tenant })
  }

  # Spanish full-text search over content, accent-insensitive, ranked by ts_rank.
  # Mirrors the GIN index expression (see the FTS migration) so the index is used.
  #
  # plainto_tsquery safely normalizes/de-stopwords arbitrary user input (no
  # injection, never raises); we then swap its AND (&) operators for OR (|) so a
  # chunk matching ANY query term is a candidate — natural-language questions
  # rarely contain every term verbatim, and ts_rank still rewards fuller matches.
  scope :full_text_search, ->(query) {
    tsv = "to_tsvector('spanish', public.immutable_unaccent(content))"
    tsq = "replace(plainto_tsquery('spanish', public.immutable_unaccent(?))::text, '&', '|')::tsquery"
    where("#{tsv} @@ #{tsq}", query)
      .order(Arel.sql("ts_rank(#{tsv}, #{sanitize_sql_array([ tsq, query ])}) DESC"))
  }
end
