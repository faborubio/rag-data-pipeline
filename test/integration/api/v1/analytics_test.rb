require "test_helper"

class Api::V1::AnalyticsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "Acme")
    QueryLog.create!(tenant: @tenant, question: "¿incendio?", answered: true, cache_hit: false, sources_count: 2)
    QueryLog.create!(tenant: @tenant, question: "¿incendio?", answered: true, cache_hit: true, sources_count: 2)
    QueryLog.create!(tenant: @tenant, question: "¿capital de Francia?", answered: false, cache_hit: false, sources_count: 0)
  end

  test "rejects unauthenticated requests" do
    get "/api/v1/analytics"
    assert_response :unauthorized
  end

  test "returns per-tenant query analytics" do
    get "/api/v1/analytics", headers: auth_headers(@tenant)
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal 3, body["total"]
    assert_equal 2, body["answered"]
    assert_equal 1, body["abstained"]
    assert_in_delta 0.333, body["cache_hit_rate"], 0.01
    assert_equal "¿incendio?", body.dig("top_questions", 0, "question")
    assert_equal 2, body.dig("top_questions", 0, "count")
    assert_equal "¿capital de Francia?", body.dig("content_gaps", 0, "question")
  end

  test "is isolated per tenant" do
    other = Tenant.create!(name: "Other")
    get "/api/v1/analytics", headers: auth_headers(other)
    assert_equal 0, JSON.parse(response.body)["total"]
  end
end
