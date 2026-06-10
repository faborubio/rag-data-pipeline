require "test_helper"

class DocumentTest < ActiveSupport::TestCase
  setup { @tenant = Tenant.create!(name: "Acme") }

  test "belongs to a tenant and requires a filename" do
    doc = Document.new(tenant: @tenant, filename: nil)
    assert_not doc.valid?
    assert_includes doc.errors[:filename], "can't be blank"
  end

  test "defaults to processing status" do
    doc = @tenant.documents.create!(filename: "a.pdf")
    assert doc.processing?
    assert_equal "processing", doc.status
  end

  test "supports the full status lifecycle" do
    doc = @tenant.documents.create!(filename: "a.pdf")
    doc.completed!
    assert doc.completed?
    doc.failed!
    assert doc.failed?
  end

  test "exposes the expected enum values" do
    assert_equal({ "processing" => 0, "completed" => 1, "failed" => 2 }, Document.statuses)
  end

  test "metadata defaults to an empty hash" do
    doc = @tenant.documents.create!(filename: "a.pdf")
    assert_equal({}, doc.metadata)
  end
end
