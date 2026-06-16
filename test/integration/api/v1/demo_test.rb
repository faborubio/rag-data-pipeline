require "test_helper"

class Api::V1::DemoTest < ActionDispatch::IntegrationTest
  test "returns the read-only demo tenant's key without authentication" do
    demo = Tenant.create!(name: "Demo Publica", read_only: true)

    get api_v1_demo_url

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal demo.api_key, body["api_key"]
    assert_equal "Demo Publica", body["tenant"]
  end

  test "flags can_upload false for a read-only tenant (prod keeps the demo read-only)" do
    Tenant.create!(name: "Demo Publica", read_only: true)

    get api_v1_demo_url

    assert_response :success
    assert_equal false, JSON.parse(response.body)["can_upload"]
  end

  test "DEMO_TENANT can serve a writable tenant and flags can_upload true" do
    writable = Tenant.create!(name: "Local Writable", read_only: false)
    ENV["DEMO_TENANT"] = "Local Writable"

    get api_v1_demo_url

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal writable.api_key, body["api_key"]
    assert_equal true, body["can_upload"]
  ensure
    ENV.delete("DEMO_TENANT")
  end

  test "404s when no demo tenant is configured" do
    Tenant.create!(name: "Regular") # not read-only

    get api_v1_demo_url
    assert_response :not_found
  end
end
