class Tenant < ApplicationRecord
  # Per-tenant upload quota (override with STORAGE_BUDGET_MB). The VPS disk holds
  # thousands of PDFs, so this is a logical guardrail against a single tenant
  # filling it, not a disk limit. Measured in uploaded file bytes (see metadata
  # byte_size on Document) — conservative vs the smaller on-disk chunk footprint.
  STORAGE_BUDGET_MB = (ENV["STORAGE_BUDGET_MB"] || 500).to_i

  has_many :documents, dependent: :destroy
  has_many :query_logs, dependent: :delete_all

  # Secret API key, encrypted at rest (Lockbox -> api_key_ciphertext) and
  # searchable via a blind index (BlindIndex -> api_key_bidx) for authentication.
  has_encrypted :api_key
  blind_index :api_key

  validates :name, presence: true
  validates :api_key, presence: true

  before_validation :ensure_credentials, on: :create

  # Authenticate a request by its raw secret key (constant-time blind index lookup).
  def self.authenticate(raw_key)
    return nil if raw_key.blank?

    find_by(api_key: raw_key)
  end

  def self.generate_api_key
    "rag_sk_#{SecureRandom.hex(24)}"
  end

  # Sum of uploaded file sizes (Document metadata.byte_size). Documents predating
  # the field count as 0, which is fine — the quota only needs to be a guardrail.
  def storage_used_bytes
    # to_i: a raw-SQL sum comes back as a String, which would break the arithmetic.
    documents.sum(Arel.sql("COALESCE((metadata->>'byte_size')::bigint, 0)")).to_i
  end

  def storage_budget_bytes = STORAGE_BUDGET_MB.megabytes

  def storage_available_bytes = [ storage_budget_bytes - storage_used_bytes, 0 ].max

  # True if a new upload of `bytes` would still fit under the budget.
  def room_for?(bytes) = storage_used_bytes + bytes.to_i <= storage_budget_bytes

  private

  def ensure_credentials
    self.api_key  ||= self.class.generate_api_key
    # Public, non-secret identifier for the key (safe to display/log).
    self.api_key_id ||= "rag_id_#{SecureRandom.hex(8)}"
  end
end
