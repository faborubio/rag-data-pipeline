require "test_helper"

class DocumentIngestionJobTest < ActiveJob::TestCase
  setup do
    @tenant = Tenant.create!(name: "Acme")
    @document = @tenant.documents.create!(filename: "manual.pdf")
  end

  # A job whose ingestion always hits the provider rate limit.
  class RateLimitedIngestionJob < DocumentIngestionJob
    class AlwaysRateLimited
      def call(*) = raise Rag::Embedder::RateLimitError, "429"
    end

    private

    def ingestor = AlwaysRateLimited.new
  end

  test "marks the document completed and creates chunks" do
    path = build_pdf(Rails.root.join("tmp", "job_test.pdf"), [ "Texto de prueba para la ingestion." ])

    DocumentIngestionJob.perform_now(@document.id, path.to_s)

    assert @document.reload.completed?
    assert_operator @document.document_chunks.count, :>=, 1
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "deletes the temp file after a successful ingestion" do
    path = build_pdf(Rails.root.join("tmp", "job_cleanup_ok.pdf"), [ "Una pagina." ])

    DocumentIngestionJob.perform_now(@document.id, path.to_s)

    assert_not File.exist?(path), "temp upload should be removed on success"
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "deletes the temp file on terminal failure" do
    path = Rails.root.join("tmp", "job_cleanup_fail_#{SecureRandom.hex(4)}.pdf")
    File.write(path, "esto no es un PDF") # extraction will raise

    job = DocumentIngestionJob.new(@document.id, path.to_s)
    job.executions = DocumentIngestionJob::MAX_ATTEMPTS - 1
    job.perform_now rescue Rag::PdfTextExtractor::ExtractionError

    assert @document.reload.failed?
    assert_not File.exist?(path), "temp upload should be removed on terminal failure"
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "a rate limit keeps the document processing and preserves the temp file" do
    path = build_pdf(Rails.root.join("tmp", "job_ratelimit.pdf"), [ "Una pagina." ])

    RateLimitedIngestionJob.perform_now(@document.id, path.to_s)

    assert @document.reload.processing?, "rate limit must not mark the document failed"
    assert File.exist?(path), "temp file must be kept so the retry can resume"
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
