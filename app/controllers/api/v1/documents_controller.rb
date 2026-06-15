require "fileutils"

module Api
  module V1
    class DocumentsController < BaseController
      # Upload ceiling. Default 160MB covers large manuals (hundreds of pages);
      # override with MAX_UPLOAD_MB. The file is streamed to disk (never read into
      # memory), so the practical limit is disk + extraction RAM, not process RAM.
      MAX_SIZE = (ENV["MAX_UPLOAD_MB"] || 160).to_i.megabytes

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
        return render_error("this tenant is read-only", :forbidden) if current_tenant.read_only?

        file = params[:file]
        return render_error("file is required", :unprocessable_entity)        if file.blank?
        return render_error("only PDF, TXT and Markdown files are allowed", :unprocessable_entity) unless accepted?(file)
        return render_error("file exceeds the #{MAX_SIZE / 1.megabyte}MB limit", :unprocessable_entity) if file.size > MAX_SIZE

        document = current_tenant.documents.create!(filename: file.original_filename, status: :processing)
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
