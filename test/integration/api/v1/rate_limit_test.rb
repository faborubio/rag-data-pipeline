require "test_helper"

class Api::V1::RateLimitTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "Acme")
    @document = @tenant.documents.create!(filename: "manual.pdf", status: :completed)

    # Rack::Attack needs a real counter store (test cache is null_store) and a
    # small limit so the test is fast.
    @original_store = Rack::Attack.cache.store
    @original_limit = RateLimit.limit
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    RateLimit.limit = 3
  end

  teardown do
    Rack::Attack.cache.store = @original_store
    RateLimit.limit = @original_limit
  end

  test "throttles a tenant after exceeding its request budget" do
    statuses = Array.new(4) do
      post api_v1_chats_query_url,
           params: { question: "x", document_ids: [ @document.id ] },
           headers: auth_headers(@tenant), as: :json
      response.status
    end

    assert_equal 429, statuses.last
    assert_includes response.body, "rate limit exceeded"
  end

  test "allows requests under the limit" do
    post api_v1_chats_query_url,
         params: { question: "x", document_ids: [ @document.id ] },
         headers: auth_headers(@tenant), as: :json
    assert_response :success
  end

  test "budgets are independent per tenant" do
    other = Tenant.create!(name: "Otra")
    3.times do
      post api_v1_chats_query_url, params: { question: "x", document_ids: [ @document.id ] },
                                   headers: auth_headers(@tenant), as: :json
    end
    # A different tenant still has its full budget.
    post api_v1_chats_query_url, params: { question: "x", document_ids: [ @document.id ] },
                                 headers: auth_headers(other), as: :json
    assert_response :success
  end
end
