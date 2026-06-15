require "test_helper"

class RootRedirectTest < ActionDispatch::IntegrationTest
  test "the bare domain redirects to the public demo page" do
    get "/"
    assert_response :redirect
    assert_redirected_to "/demo.html"
  end
end
