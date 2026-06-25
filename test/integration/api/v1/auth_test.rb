require "test_helper"

class Api::V1::AuthTest < ActionDispatch::IntegrationTest
  setup do
    # Two fixed accounts sharing one read-only corpus tenant (admin curates).
    @corpus = Tenant.create!(name: "Demo", read_only: true)
    @admin = User.create!(email: "admin@x.com", password: "secret123", role: "admin", tenant: @corpus)
    @visitor = User.create!(email: "visit@x.com", password: "secret123", role: "visitor", tenant: @corpus)
    @pdf_path = build_pdf(Rails.root.join("tmp", "auth_doc.pdf"), [ "Contenido de prueba." ])
  end

  teardown { File.delete(@pdf_path) if @pdf_path && File.exist?(@pdf_path) }

  test "login returns the user's api key and role" do
    post api_v1_login_url, params: { email: "admin@x.com", password: "secret123" }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @admin.api_key, body["api_key"]
    assert_equal "admin", body["role"]
  end

  test "login rejects wrong passwords and unknown emails alike (no enumeration)" do
    post api_v1_login_url, params: { email: "admin@x.com", password: "wrongpass1" }, as: :json
    assert_response :unauthorized
    post api_v1_login_url, params: { email: "nope@x.com", password: "whatever1" }, as: :json
    assert_response :unauthorized
  end

  test "public signup no longer exists" do
    post "/api/v1/signup", params: { email: "x@x.com", password: "secret123" }, as: :json
    assert_response :not_found
  end

  test "a user key authenticates protected endpoints" do
    get api_v1_storage_url, headers: bearer(@visitor.api_key)
    assert_response :success
  end

  test "admin can upload to the shared corpus (role overrides read-only tenant)" do
    assert_difference -> { @corpus.documents.count }, 1 do
      post api_v1_documents_url, params: { file: pdf_upload }, headers: bearer(@admin.api_key)
    end
    assert_response :accepted
  end

  test "visitor cannot upload but reads the same curated corpus" do
    post api_v1_documents_url, params: { file: pdf_upload }, headers: bearer(@visitor.api_key)
    assert_response :forbidden

    @corpus.documents.create!(filename: "curated.pdf", status: :completed)
    get api_v1_documents_url, headers: bearer(@visitor.api_key)
    assert_equal %w[curated.pdf], JSON.parse(response.body).map { |d| d["filename"] }
  end

  test "the anonymous read-only tenant key cannot upload" do
    post api_v1_documents_url, params: { file: pdf_upload }, headers: bearer(@corpus.api_key)
    assert_response :forbidden
  end

  private

  def bearer(key) = { "Authorization" => "Bearer #{key}" }

  def pdf_upload
    Rack::Test::UploadedFile.new(@pdf_path, "application/pdf")
  end
end
