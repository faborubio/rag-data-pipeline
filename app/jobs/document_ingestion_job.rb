class DocumentIngestionJob < ApplicationJob
  MAX_ATTEMPTS = 5

  queue_as :ingestion

  # Resilience (spec): automatic retries with exponential backoff. The document
  # is only marked failed once the LAST attempt fails (see the rescue); while
  # retries remain it stays `processing` so status never flaps to failed.
  retry_on StandardError, wait: :polynomially_longer, attempts: MAX_ATTEMPTS

  def perform(document_id, file_path)
    document = Document.find(document_id)
    document.processing!

    chunk_count = Rag::Ingestor.new.call(document, file_path)

    document.completed!
    cleanup(file_path)
    AppMetrics::INGESTIONS.increment(labels: { status: "completed" })
    Rails.logger.info("[Ingestion] document=#{document_id} chunks=#{chunk_count} -> completed")
  rescue ActiveRecord::RecordNotFound => e
    # Document was deleted; nothing to retry.
    Rails.logger.warn("[Ingestion] #{e.message}; skipping")
  rescue StandardError => e
    if executions >= MAX_ATTEMPTS
      # Final attempt: give up and record the failure terminally.
      Document.where(id: document_id).update_all(status: Document.statuses[:failed])
      AppMetrics::INGESTIONS.increment(labels: { status: "failed" })
      Rails.logger.error("[Ingestion] document=#{document_id} failed after #{executions} attempts: #{e.class}: #{e.message}")
    else
      Rails.logger.warn("[Ingestion] document=#{document_id} attempt #{executions} failed (#{e.class}); will retry")
    end
    raise e
  end

  private

  def cleanup(file_path)
    File.delete(file_path) if file_path && File.exist?(file_path)
  rescue StandardError => e
    Rails.logger.warn("[Ingestion] could not delete #{file_path}: #{e.message}")
  end
end
