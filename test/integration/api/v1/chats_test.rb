require "test_helper"

class Api::V1::ChatsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "Acme")
    @document = @tenant.documents.create!(filename: "manual.pdf", status: :completed)
    embedder = Rag::Embedder.new(api_key: nil)
    @document.document_chunks.create!(
      content: "Protocolo de incendio: evacuar por las escaleras.",
      page_number: 12, embedding: embedder.embed_one("Protocolo de incendio: evacuar por las escaleras.")
    )
  end

  test "requires authentication" do
    post api_v1_chats_query_url, params: { question: "x", document_ids: [ @document.id ] }, as: :json
    assert_response :unauthorized
  end

  test "returns answer, sources and latency for an authenticated query" do
    post api_v1_chats_query_url,
         params: { question: "¿Qué hago en caso de incendio?", document_ids: [ @document.id ] },
         headers: auth_headers(@tenant), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body["answer"].present?
    assert_kind_of Array, body["sources"]
    assert body.key?("latency_ms")
  end

  test "validates required params" do
    post api_v1_chats_query_url,
         params: { question: "", document_ids: [] },
         headers: auth_headers(@tenant), as: :json
    assert_response :unprocessable_entity
  end

  test "rejects a query with too many document_ids" do
    ids = Array.new(Api::V1::ChatsController::MAX_DOCUMENT_IDS + 1) { SecureRandom.uuid }
    post api_v1_chats_query_url,
         params: { question: "incendio", document_ids: ids },
         headers: auth_headers(@tenant), as: :json
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "too many"
  end

  test "rejects a query with an over-long question" do
    post api_v1_chats_query_url,
         params: { question: "a" * (Api::V1::ChatsController::MAX_QUESTION_LENGTH + 1), document_ids: [ @document.id ] },
         headers: auth_headers(@tenant), as: :json
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "too long"
  end

  test "reports still-processing when the tenant's documents are not yet indexed" do
    doc = @tenant.documents.create!(filename: "indexing.pdf", status: :processing)
    post api_v1_chats_query_url,
         params: { question: "¿algo?", document_ids: [ doc.id ] },
         headers: auth_headers(@tenant), as: :json

    assert_response :accepted
    body = JSON.parse(response.body)
    assert_equal true, body["processing"]
    assert_empty body["sources"]
  end

  test "does not leak chunks from another tenant" do
    other = Tenant.create!(name: "Otra")
    post api_v1_chats_query_url,
         params: { question: "incendio", document_ids: [ @document.id ] },
         headers: auth_headers(other), as: :json

    assert_response :success
    assert_empty JSON.parse(response.body)["sources"]
  end
end
