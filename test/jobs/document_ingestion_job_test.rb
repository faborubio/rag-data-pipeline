require "test_helper"

class DocumentIngestionJobTest < ActiveJob::TestCase
  setup do
    @tenant = Tenant.create!(name: "Acme")
    @document = @tenant.documents.create!(filename: "manual.pdf")
  end

  test "marks the document completed and creates chunks" do
    path = build_pdf(Rails.root.join("tmp", "job_test.pdf"), [ "Texto de prueba para la ingestion." ])

    DocumentIngestionJob.perform_now(@document.id, path.to_s)

    assert @document.reload.completed?
    assert_operator @document.document_chunks.count, :>=, 1
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "marks the document failed when extraction fails" do
    DocumentIngestionJob.perform_now(@document.id, "/nonexistent/missing.pdf")
    assert @document.reload.failed?
  end
end
