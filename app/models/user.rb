class User < ApplicationRecord
  has_secure_password
  # All accounts share one corpus tenant; the role decides who can write.
  belongs_to :tenant

  # Per-user secret API key, encrypted at rest + searchable via blind index
  # (same pattern as Tenant) — this is what the demo stores after login and what
  # BaseController resolves to (user → tenant + role).
  has_encrypted :api_key
  blind_index :api_key

  enum :role, { visitor: "visitor", admin: "admin" }, default: "visitor"

  EMAIL_REGEX = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

  validates :email, presence: true, uniqueness: { case_sensitive: false }, format: { with: EMAIL_REGEX }
  validates :password, length: { minimum: 8 }, allow_nil: true
  validates :api_key, presence: true

  before_validation :ensure_api_key, on: :create

  # Authenticate a request by its raw secret key (constant-time blind index lookup).
  def self.authenticate(raw_key)
    return nil if raw_key.blank?

    find_by(api_key: raw_key)
  end

  private

  def ensure_api_key
    self.api_key  ||= "rag_uk_#{SecureRandom.hex(24)}"
    self.api_key_id ||= "rag_uid_#{SecureRandom.hex(8)}"
  end
end
