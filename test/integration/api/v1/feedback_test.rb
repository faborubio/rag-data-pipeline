require "test_helper"

class Api::V1::FeedbackTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "Acme")
    @log = QueryLog.create!(tenant: @tenant, question: "¿incendio?", answered: true, cache_hit: false, sources_count: 1)
  end

  test "requires authentication" do
    post "/api/v1/feedback", params: { query_id: @log.id, rating: 1 }
    assert_response :unauthorized
  end

  test "records a thumbs up" do
    post "/api/v1/feedback", params: { query_id: @log.id, rating: 1 }, headers: auth_headers(@tenant)
    assert_response :success
    assert_equal 1, @log.reload.rating
  end

  test "records a thumbs down" do
    post "/api/v1/feedback", params: { query_id: @log.id, rating: -1 }, headers: auth_headers(@tenant)
    assert_response :success
    assert_equal(-1, @log.reload.rating)
  end

  test "rejects an invalid rating" do
    post "/api/v1/feedback", params: { query_id: @log.id, rating: 5 }, headers: auth_headers(@tenant)
    assert_response :unprocessable_entity
  end

  test "cannot rate another tenant's query" do
    other = Tenant.create!(name: "Other")
    post "/api/v1/feedback", params: { query_id: @log.id, rating: 1 }, headers: auth_headers(other)
    assert_response :not_found
    assert_nil @log.reload.rating
  end
end
