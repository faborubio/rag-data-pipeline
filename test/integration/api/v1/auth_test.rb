require "test_helper"

class Api::V1::AuthTest < ActionDispatch::IntegrationTest
  test "signup creates a user with their own writable tenant and returns its api key" do
    assert_difference -> { User.count } => 1, -> { Tenant.count } => 1 do
      post api_v1_signup_url, params: { email: "a@b.com", password: "secret123" }, as: :json
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "a@b.com", body["email"]

    user = User.find_by(email: "a@b.com")
    assert_not user.tenant.read_only?, "the user's tenant must be writable"
    assert_equal user.tenant.api_key, body["api_key"]
  end

  test "rejects a duplicate email (case-insensitive)" do
    User.register(email: "dup@b.com", password: "secret123")
    assert_no_difference -> { User.count } do
      post api_v1_signup_url, params: { email: "DUP@b.com", password: "another1" }, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "rejects a short password" do
    post api_v1_signup_url, params: { email: "x@b.com", password: "short" }, as: :json
    assert_response :unprocessable_entity
  end

  test "login returns the api key for valid credentials" do
    User.register(email: "log@b.com", password: "secret123")
    post api_v1_login_url, params: { email: "log@b.com", password: "secret123" }, as: :json
    assert_response :success
    assert JSON.parse(response.body)["api_key"].present?
  end

  test "login rejects wrong passwords and unknown emails alike (no enumeration)" do
    User.register(email: "log@b.com", password: "secret123")
    post api_v1_login_url, params: { email: "log@b.com", password: "wrongpass1" }, as: :json
    assert_response :unauthorized
    post api_v1_login_url, params: { email: "nope@b.com", password: "whatever1" }, as: :json
    assert_response :unauthorized
  end

  test "the issued api key authenticates protected endpoints" do
    post api_v1_signup_url, params: { email: "auth@b.com", password: "secret123" }, as: :json
    key = JSON.parse(response.body)["api_key"]
    get api_v1_storage_url, headers: { "Authorization" => "Bearer #{key}" }
    assert_response :success
  end

  test "each user only sees their own documents (tenant isolation)" do
    post api_v1_signup_url, params: { email: "u1@b.com", password: "secret123" }, as: :json
    k1 = JSON.parse(response.body)["api_key"]
    post api_v1_signup_url, params: { email: "u2@b.com", password: "secret123" }, as: :json
    k2 = JSON.parse(response.body)["api_key"]
    User.find_by(email: "u1@b.com").tenant.documents.create!(filename: "mine.pdf", status: :completed)

    get api_v1_documents_url, headers: { "Authorization" => "Bearer #{k2}" }
    assert_empty JSON.parse(response.body), "u2 must not see u1's documents"
    get api_v1_documents_url, headers: { "Authorization" => "Bearer #{k1}" }
    assert_equal %w[mine.pdf], JSON.parse(response.body).map { |d| d["filename"] }
  end
end
