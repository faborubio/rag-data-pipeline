require "test_helper"

class Api::V1::DocumentsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @tenant = Tenant.create!(name: "Acme")
    @pdf_path = build_pdf(Rails.root.join("tmp", "req_doc.pdf"), [ "Contenido de prueba para subir." ])
  end

  teardown { File.delete(@pdf_path) if @pdf_path && File.exist?(@pdf_path) }

  test "rejects unauthenticated uploads" do
    post api_v1_documents_url, params: { file: pdf_upload }
    assert_response :unauthorized
  end

  test "accepts a valid pdf and enqueues ingestion" do
    assert_enqueued_with(job: DocumentIngestionJob) do
      post api_v1_documents_url, params: { file: pdf_upload }, headers: auth_headers(@tenant)
    end

    assert_response :accepted
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert_equal "processing", body["status"]
  end

  test "rejects unsupported file types" do
    csv = Rails.root.join("tmp", "data.csv")
    File.write(csv, "a,b,c")
    post api_v1_documents_url,
         params: { file: Rack::Test::UploadedFile.new(csv, "text/csv") },
         headers: auth_headers(@tenant)
    assert_response :unprocessable_entity
  ensure
    File.delete(csv) if csv && File.exist?(csv)
  end

  test "accepts a plain-text file and enqueues ingestion" do
    txt = Rails.root.join("tmp", "notes.txt")
    File.write(txt, "Notas sobre seguridad e incendios.")
    assert_enqueued_with(job: DocumentIngestionJob) do
      post api_v1_documents_url,
           params: { file: Rack::Test::UploadedFile.new(txt, "text/plain") },
           headers: auth_headers(@tenant)
    end
    assert_response :accepted
  ensure
    File.delete(txt) if txt && File.exist?(txt)
  end

  test "rejects a non-pdf disguised with a .pdf extension" do
    fake = Rails.root.join("tmp", "fake.pdf")
    File.write(fake, "This is plain text, not a PDF.")
    post api_v1_documents_url,
         params: { file: Rack::Test::UploadedFile.new(fake, "application/pdf") },
         headers: auth_headers(@tenant)
    assert_response :unprocessable_entity
  ensure
    File.delete(fake) if fake && File.exist?(fake)
  end

  test "records the uploaded file size for the storage quota" do
    post api_v1_documents_url, params: { file: pdf_upload }, headers: auth_headers(@tenant)
    assert_response :accepted
    assert_operator @tenant.documents.order(:created_at).last.metadata["byte_size"].to_i, :>, 0
  end

  test "rejects an upload that would exceed the storage quota" do
    @tenant.documents.create!(filename: "big.pdf", status: :completed,
                              metadata: { byte_size: Tenant::STORAGE_BUDGET_MB.megabytes })
    post api_v1_documents_url, params: { file: pdf_upload }, headers: auth_headers(@tenant)
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "quota"
  end

  test "read-only tenants cannot upload" do
    @tenant.update!(read_only: true)
    post api_v1_documents_url, params: { file: pdf_upload }, headers: auth_headers(@tenant)
    assert_response :forbidden
    assert_includes JSON.parse(response.body)["error"], "read-only"
  end

  test "shows a document belonging to the tenant" do
    document = @tenant.documents.create!(filename: "a.pdf", status: :completed)
    get api_v1_document_url(document), headers: auth_headers(@tenant)

    assert_response :success
    assert_equal "completed", JSON.parse(response.body)["status"]
  end

  test "lists only the tenant's documents with chunk counts" do
    doc = @tenant.documents.create!(filename: "mine.pdf", status: :completed)
    doc.document_chunks.create!(content: "x", page_number: 1, embedding: sample_vector)
    Tenant.create!(name: "Otra").documents.create!(filename: "theirs.pdf")

    get api_v1_documents_url, headers: auth_headers(@tenant)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal %w[mine.pdf], body.map { |d| d["filename"] }
    assert_equal 1, body.first["chunks"]
  end

  private

  def pdf_upload
    Rack::Test::UploadedFile.new(@pdf_path, "application/pdf")
  end
end
