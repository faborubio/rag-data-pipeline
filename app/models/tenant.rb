class Tenant < ApplicationRecord
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

  private

  def ensure_credentials
    self.api_key  ||= self.class.generate_api_key
    # Public, non-secret identifier for the key (safe to display/log).
    self.api_key_id ||= "rag_id_#{SecureRandom.hex(8)}"
  end
end
