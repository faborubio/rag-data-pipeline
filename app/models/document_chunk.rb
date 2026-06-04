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
end
