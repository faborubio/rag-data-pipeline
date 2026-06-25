class User < ApplicationRecord
  has_secure_password
  # Each user owns one writable tenant — their private, isolated workspace. The
  # tenant's API key is what the demo uses to upload/query after login.
  belongs_to :tenant

  EMAIL_REGEX = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

  validates :email, presence: true, uniqueness: { case_sensitive: false }, format: { with: EMAIL_REGEX }
  validates :password, length: { minimum: 8 }, allow_nil: true

  # Creates the user together with their own writable tenant, atomically: if the
  # user is invalid (dup email, weak password), the tenant is rolled back too.
  def self.register(email:, password:)
    transaction do
      tenant = Tenant.create!(name: "user:#{email}", read_only: false)
      create!(email: email, password: password, tenant: tenant)
    end
  end
end
