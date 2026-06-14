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

  test "stays processing while retries remain (non-final failure)" do
    # First attempt fails; retry_on re-enqueues it and swallows the error. The
    # document must NOT flap to failed while retries remain.
    DocumentIngestionJob.perform_now(@document.id, "/nonexistent/missing.pdf")
    assert @document.reload.processing?, "should stay processing until retries are exhausted"
  end

  test "marks the document failed only on the final attempt" do
    # Drive the job to its last attempt: perform_now takes executions to
    # MAX_ATTEMPTS, so retry_on stops retrying and the rescue records failure.
    job = DocumentIngestionJob.new(@document.id, "/nonexistent/missing.pdf")
    job.executions = DocumentIngestionJob::MAX_ATTEMPTS - 1

    # retry_on may or may not re-raise once attempts are exhausted; either way
    # the terminal failure must be recorded on this last attempt.
    job.perform_now rescue Rag::PdfTextExtractor::ExtractionError
    assert @document.reload.failed?
  end
end
