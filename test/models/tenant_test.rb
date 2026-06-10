require "test_helper"

class TenantTest < ActiveSupport::TestCase
  test "is valid with a name and auto-generates credentials" do
    tenant = Tenant.create!(name: "Acme")
    assert tenant.persisted?
    assert tenant.api_key.start_with?("rag_sk_"), "api_key should be auto-generated"
    assert tenant.api_key_id.start_with?("rag_id_"), "public api_key_id should be set"
  end

  test "requires a name" do
    tenant = Tenant.new(name: nil)
    assert_not tenant.valid?
    assert_includes tenant.errors[:name], "can't be blank"
  end

  test "stores the api_key encrypted, never in plaintext" do
    tenant = Tenant.create!(name: "Acme")
    raw = tenant.api_key
    row = Tenant.connection.select_one(
      Tenant.sanitize_sql_array([ "SELECT api_key_ciphertext, api_key_bidx FROM tenants WHERE id = ?", tenant.id ])
    )
    assert row["api_key_ciphertext"].present?, "ciphertext column should be populated"
    assert row["api_key_bidx"].present?, "blind index column should be populated"
    assert_not row["api_key_ciphertext"].to_s.include?(raw), "plaintext must not be stored"
  end

  test "authenticate returns the tenant for the correct key" do
    tenant = Tenant.create!(name: "Acme")
    assert_equal tenant, Tenant.authenticate(tenant.api_key)
  end

  test "authenticate returns nil for a wrong or blank key" do
    Tenant.create!(name: "Acme")
    assert_nil Tenant.authenticate("rag_sk_wrong")
    assert_nil Tenant.authenticate("")
    assert_nil Tenant.authenticate(nil)
  end

  test "destroys dependent documents" do
    tenant = Tenant.create!(name: "Acme")
    tenant.documents.create!(filename: "a.pdf")
    assert_difference("Document.count", -1) { tenant.destroy }
  end
end
