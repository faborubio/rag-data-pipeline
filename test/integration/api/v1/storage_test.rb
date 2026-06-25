require "test_helper"

class Api::V1::StorageTest < ActionDispatch::IntegrationTest
  setup { @tenant = Tenant.create!(name: "Acme") }

  test "requires authentication" do
    get api_v1_storage_url
    assert_response :unauthorized
  end

  test "reports the budget, zero used and full availability for a fresh tenant" do
    get api_v1_storage_url, headers: auth_headers(@tenant)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal Tenant::STORAGE_BUDGET_MB.to_f, body["budget_mb"]
    assert_equal 0.0, body["used_mb"]
    assert_operator body["available_mb"], :>, 0
  end

  test "reflects an uploaded document's size in used and available" do
    @tenant.documents.create!(filename: "a.pdf", status: :completed, metadata: { byte_size: 10.megabytes })

    get api_v1_storage_url, headers: auth_headers(@tenant)

    body = JSON.parse(response.body)
    assert_in_delta 10.0, body["used_mb"], 0.1
    assert_in_delta Tenant::STORAGE_BUDGET_MB - 10, body["available_mb"], 0.1
    assert_operator body["max_upload_mb"], :<=, body["available_mb"]
  end
end
