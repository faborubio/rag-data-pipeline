require "test_helper"

# Suite adversarial de aislamiento multi-tenant (ver docs/SECURITY.md): un
# tenant atacante autenticado sondea cada endpoint con los ids de la víctima
# intentando leer, inferir o degradar datos ajenos. El corpus de la víctima
# lleva un canario que no debe aparecer jamás en una respuesta al atacante.
class Api::V1::TenantIsolationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  CANARY = "canario-7f3a-confidencial".freeze

  setup do
    @victim   = Tenant.create!(name: "Victima")
    @attacker = Tenant.create!(name: "Atacante")

    embedder = Rag::Embedder.new(api_key: nil)
    victim_content = "Protocolo #{CANARY}: en caso de incendio evacuar por la escalera norte."
    @victim_doc = @victim.documents.create!(filename: "secreto.pdf", status: :completed)
    @victim_doc.document_chunks.create!(
      content: victim_content, page_number: 3, embedding: embedder.embed_one(victim_content)
    )

    attacker_content = "Manual propio: el incendio se apaga con el extintor del pasillo."
    @attacker_doc = @attacker.documents.create!(filename: "propio.pdf", status: :completed)
    @attacker_doc.document_chunks.create!(
      content: attacker_content, page_number: 1, embedding: embedder.embed_one(attacker_content)
    )
  end

  test "cannot read another tenant's document by id" do
    get api_v1_document_url(@victim_doc), headers: auth_headers(@attacker)

    assert_response :not_found
    refute_includes response.body, @victim_doc.filename
  end

  test "a query mixing own and foreign document ids only surfaces own chunks" do
    post api_v1_chats_query_url,
         params: { question: "¿Cómo se apaga un incendio?",
                   document_ids: [ @attacker_doc.id, @victim_doc.id ] },
         headers: auth_headers(@attacker), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ @attacker_doc.id ], body["sources"].map { |s| s["document_id"] }.uniq
    refute_includes response.body, CANARY
  end

  test "a foreign processing document does not reveal its indexing state" do
    processing = @victim.documents.create!(filename: "indexando.pdf", status: :processing)

    post api_v1_chats_query_url,
         params: { question: "¿Qué contiene ese documento?", document_ids: [ processing.id ] },
         headers: auth_headers(@attacker), as: :json

    # Un 202/processing:true aquí confirmaría al atacante que el id existe y
    # está indexándose; debe caer en la respuesta normal de fuentes vacías.
    assert_response :success
    body = JSON.parse(response.body)
    refute body["processing"]
    assert_empty body["sources"]
  end

  test "the answer cache never crosses tenants" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    question = "¿Por dónde se evacúa en un incendio?"
    post api_v1_chats_query_url,
         params: { question: question, document_ids: [ @victim_doc.id ] },
         headers: auth_headers(@victim), as: :json
    assert_response :success
    assert_includes response.body, CANARY

    # La misma pregunta + los mismos ids desde el atacante no puede rescatar
    # la entrada cacheada de la víctima.
    post api_v1_chats_query_url,
         params: { question: question, document_ids: [ @victim_doc.id ] },
         headers: auth_headers(@attacker), as: :json
    assert_response :success
    assert_empty JSON.parse(response.body)["sources"]
    refute_includes response.body, CANARY
  ensure
    Rails.cache = original_cache
  end

  test "another tenant's ingestion backlog does not block uploads" do
    Api::V1::DocumentsController::MAX_INFLIGHT.times do |i|
      @victim.documents.create!(filename: "bomba-#{i}.pdf", status: :processing)
    end

    pdf_path = build_pdf(Rails.root.join("tmp", "isolation_upload.pdf"), [ "Contenido propio." ])
    post api_v1_documents_url,
         params: { file: Rack::Test::UploadedFile.new(pdf_path, "application/pdf") },
         headers: auth_headers(@attacker)

    assert_response :accepted
  ensure
    File.delete(pdf_path) if pdf_path && File.exist?(pdf_path)
  end

  test "storage usage never counts another tenant's documents" do
    @victim_doc.update!(metadata: { byte_size: 50.megabytes })

    get api_v1_storage_url, headers: auth_headers(@attacker)

    assert_response :success
    assert_equal 0.0, JSON.parse(response.body)["used_mb"]
  end
end
