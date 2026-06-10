class DocumentIngestionJob < ApplicationJob
  queue_as :ingestion

  # Resilience (spec): automatic retries with exponential backoff. After the
  # final attempt the document is marked failed via the rescue below.
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

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
    Document.where(id: document_id).update_all(status: Document.statuses[:failed])
    AppMetrics::INGESTIONS.increment(labels: { status: "failed" })
    Rails.logger.error("[Ingestion] document=#{document_id} failed: #{e.class}: #{e.message}")
    raise e
  end

  private

  def cleanup(file_path)
    File.delete(file_path) if file_path && File.exist?(file_path)
  rescue StandardError => e
    Rails.logger.warn("[Ingestion] could not delete #{file_path}: #{e.message}")
  end
end
