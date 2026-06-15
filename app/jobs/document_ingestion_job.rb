class DocumentIngestionJob < ApplicationJob
  MAX_ATTEMPTS = 5
  # Rate limits are not failures: the free tier just needs time (and the embedder
  # caches what it already computed, so each retry resumes rather than restarts).
  # We retry hourly for a while; a genuinely huge doc that needs many days should
  # use `rake rag:ingest` instead of the upload path.
  RATE_LIMIT_ATTEMPTS = 6

  queue_as :ingestion

  # Resilience (spec): automatic retries with exponential backoff. The document
  # is only marked failed once the LAST attempt fails (see the rescue); while
  # retries remain it stays `processing` so status never flaps to failed.
  # NOTE: declare the specific handler LAST — rescue_from matches most-recent
  # first, so RateLimitError must be registered after the StandardError catch-all.
  retry_on StandardError, wait: :polynomially_longer, attempts: MAX_ATTEMPTS

  # A rate-limited ingest keeps retrying without being marked failed. If it stays
  # limited past RATE_LIMIT_ATTEMPTS, give up cleanly: mark failed and delete the
  # temp file (otherwise it would linger forever).
  retry_on Rag::Embedder::RateLimitError, wait: 1.hour, attempts: RATE_LIMIT_ATTEMPTS do |job, _error|
    document_id, file_path = job.arguments
    Document.where(id: document_id).update_all(status: Document.statuses[:failed])
    job.send(:cleanup, file_path)
    AppMetrics::INGESTIONS.increment(labels: { status: "failed" })
    Rails.logger.error("[Ingestion] document=#{document_id} gave up after sustained rate limiting")
  end

  def perform(document_id, file_path)
    document = Document.find(document_id)
    document.processing!

    chunk_count = ingestor.call(document, file_path)

    document.completed!
    cleanup(file_path)
    AppMetrics::INGESTIONS.increment(labels: { status: "completed" })
    Rails.logger.info("[Ingestion] document=#{document_id} chunks=#{chunk_count} -> completed")
  rescue Rag::Embedder::RateLimitError
    # Backpressure, not a failure: leave the doc `processing` and the temp file in
    # place so the scheduled retry resumes from the embedder cache.
    Rails.logger.warn("[Ingestion] document=#{document_id} rate-limited; will resume on retry")
    raise
  rescue ActiveRecord::RecordNotFound => e
    # Document was deleted; nothing to retry, but the upload is now orphaned.
    cleanup(file_path)
    Rails.logger.warn("[Ingestion] #{e.message}; skipping")
  rescue StandardError => e
    if executions >= MAX_ATTEMPTS
      # Final attempt: give up terminally and remove the temp file.
      Document.where(id: document_id).update_all(status: Document.statuses[:failed])
      cleanup(file_path)
      AppMetrics::INGESTIONS.increment(labels: { status: "failed" })
      Rails.logger.error("[Ingestion] document=#{document_id} failed after #{executions} attempts: #{e.class}: #{e.message}")
    else
      Rails.logger.warn("[Ingestion] document=#{document_id} attempt #{executions} failed (#{e.class}); will retry")
    end
    raise e
  end

  private

  # Overridable seam (tests inject a failing ingestor).
  def ingestor
    Rag::Ingestor.new
  end

  def cleanup(file_path)
    File.delete(file_path) if file_path && File.exist?(file_path)
  rescue StandardError => e
    Rails.logger.warn("[Ingestion] could not delete #{file_path}: #{e.message}")
  end
end
