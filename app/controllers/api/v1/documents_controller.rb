require "fileutils"

module Api
  module V1
    class DocumentsController < BaseController
      # Upload ceiling. Default 160MB covers large manuals (hundreds of pages);
      # override with MAX_UPLOAD_MB. The file is streamed to disk (never read into
      # memory), so the practical limit is disk + extraction RAM, not process RAM.
      MAX_SIZE = (ENV["MAX_UPLOAD_MB"] || 160).to_i.megabytes

      # Cap how many ingestions a single tenant can have in flight at once. The
      # write path runs on one Solid Queue worker; without a cap a tenant could
      # queue dozens of large (or CPU-bomb) PDFs and starve every other tenant's
      # ingestion. New uploads beyond this get 429 until earlier ones finish.
      MAX_INFLIGHT = (ENV["MAX_INFLIGHT_INGESTIONS"] || 5).to_i

      # GET /api/v1/documents
      def index
        documents = current_tenant.documents
                                   .left_joins(:document_chunks)
                                   .select("documents.*, COUNT(document_chunks.id) AS chunks_count")
                                   .group("documents.id")
                                   .order(created_at: :desc)
                                   .limit(100)
        render json: documents.map { |d| serialize(d).merge(chunks: d.chunks_count.to_i) }
      end

      # POST /api/v1/documents  (multipart, field: file)
      def create
        return render_error("this account cannot upload", :forbidden) unless can_upload?

        file = params[:file]
        return render_error("file is required", :unprocessable_entity)        if file.blank?
        return render_error("only PDF, TXT and Markdown files are allowed", :unprocessable_entity) unless accepted?(file)
        return render_error("file exceeds the #{MAX_SIZE / 1.megabyte}MB limit", :unprocessable_entity) if file.size > MAX_SIZE

        # Re-check quota + in-flight cap while holding a row lock on the tenant, so
        # two concurrent uploads can't both pass the check and blow past the budget
        # (TOCTOU). `next` keeps the early exit block-local (no transaction-return).
        document = current_tenant.with_lock do
          next :over_quota unless current_tenant.room_for?(file.size)
          next :too_many   if too_many_inflight?

          current_tenant.documents.create!(
            filename: file.original_filename, status: :processing,
            metadata: { byte_size: file.size }
          )
        end
        return render_error("storage quota exceeded", :unprocessable_entity) if document == :over_quota
        return render_error("too many documents are still processing; retry once they finish", :too_many_requests) if document == :too_many

        path = store(file)
        DocumentIngestionJob.perform_later(document.id, path.to_s)

        render json: serialize(document), status: :accepted
      end

      # GET /api/v1/documents/:id
      def show
        document = current_tenant.documents.find(params[:id])
        render json: serialize(document).merge(chunks: document.document_chunks.count)
      end

      private

      # Who may upload: a logged-in admin (role overrides the tenant's read_only,
      # so admins curate even a read-only public corpus); otherwise — anonymous or
      # local dev with no user — fall back to the tenant's writability. Visitors
      # (a non-admin user) and the read-only anonymous demo are blocked.
      def can_upload?
        return Current.user.admin? if Current.user

        !current_tenant.read_only?
      end

      # Backpressure: true when the tenant already has MAX_INFLIGHT documents
      # still being ingested, so a flood of uploads can't monopolize the worker.
      def too_many_inflight?
        MAX_INFLIGHT.positive? && current_tenant.documents.processing.count >= MAX_INFLIGHT
      end

      # Accept by extension; for PDFs also check the magic bytes so a non-PDF
      # renamed to .pdf is rejected up front instead of failing later in pdftotext.
      def accepted?(file)
        ext = File.extname(file.original_filename.to_s).downcase
        return false unless Rag::ACCEPTED_EXTENSIONS.include?(ext)
        return true unless Rag::PDF_EXTENSIONS.include?(ext)

        header = file.read(5)
        file.rewind
        header == "%PDF-"
      end

      def store(file)
        dir = Rails.root.join("tmp", "uploads")
        FileUtils.mkdir_p(dir)
        # Preserve the real extension so the ingestor picks the right extractor.
        ext = File.extname(file.original_filename.to_s).downcase
        path = dir.join("#{SecureRandom.uuid}#{ext}")
        # Rack already buffered the upload to a tempfile on disk; stream-copy it
        # so a 100MB+ file never lands in process memory.
        file.rewind
        IO.copy_stream(file.tempfile, path)
        path
      end

      def serialize(document)
        { id: document.id, filename: document.filename, status: document.status }
      end
    end
  end
end
