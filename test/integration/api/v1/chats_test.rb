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

  test "does not leak chunks from another tenant" do
    other = Tenant.create!(name: "Otra")
    post api_v1_chats_query_url,
         params: { question: "incendio", document_ids: [ @document.id ] },
         headers: auth_headers(other), as: :json

    assert_response :success
    assert_empty JSON.parse(response.body)["sources"]
  end
end
