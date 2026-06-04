class Document < ApplicationRecord
  belongs_to :tenant
  has_many :document_chunks, dependent: :destroy

  # Ingestion lifecycle (backed by the integer `status` column)
  enum :status, { processing: 0, completed: 1, failed: 2 }, default: :processing

  validates :filename, presence: true
end
