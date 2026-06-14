require "fileutils"

module Api
  module V1
    class DocumentsController < BaseController
      MAX_SIZE = 20.megabytes

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
        return render_error("only .pdf files are allowed", :unprocessable_entity) unless pdf?(file)
        return render_error("file exceeds the 20MB limit", :unprocessable_entity) if file.size > MAX_SIZE

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

      # Validate both the extension and the magic bytes, so a non-PDF renamed
      # to .pdf is rejected up front instead of failing later in pdftotext.
      def pdf?(file)
        return false unless File.extname(file.original_filename.to_s).downcase == ".pdf"

        header = file.read(5)
        file.rewind
        header == "%PDF-"
      end

      def store(file)
        dir = Rails.root.join("tmp", "uploads")
        FileUtils.mkdir_p(dir)
        path = dir.join("#{SecureRandom.uuid}.pdf")
        File.binwrite(path, file.read)
        path
      end

      def serialize(document)
        { id: document.id, filename: document.filename, status: document.status }
      end
    end
  end
end
