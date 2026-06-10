require "test_helper"

class Api::V1::DocumentsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @tenant = Tenant.create!(name: "Acme")
    @pdf_path = build_pdf(Rails.root.join("tmp", "req_doc.pdf"), ["Contenido de prueba para subir."])
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

  test "rejects non-pdf files" do
    txt = Rails.root.join("tmp", "not_pdf.txt")
    File.write(txt, "hola")
    post api_v1_documents_url,
         params: { file: Rack::Test::UploadedFile.new(txt, "text/plain") },
         headers: auth_headers(@tenant)
    assert_response :unprocessable_entity
  ensure
    File.delete(txt) if txt && File.exist?(txt)
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
