require "test_helper"

class MetricsTest < ActionDispatch::IntegrationTest
  test "exposes Prometheus metrics without tenant auth" do
    get metrics_url

    assert_response :success
    assert_match %r{text/plain}, response.media_type
    assert_includes response.body, "rag_queries_total"
    assert_includes response.body, "rag_query_latency_seconds"
  end

  test "requires a bearer token when METRICS_TOKEN is set" do
    ENV["METRICS_TOKEN"] = "secret-123"

    get metrics_url
    assert_response :unauthorized

    get metrics_url, headers: { "Authorization" => "Bearer secret-123" }
    assert_response :success
  ensure
    ENV.delete("METRICS_TOKEN")
  end
end
