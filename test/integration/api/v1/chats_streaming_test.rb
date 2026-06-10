require "test_helper"

class Api::V1::ChatsStreamingTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "Acme")
    @document = @tenant.documents.create!(filename: "manual.pdf", status: :completed)
    embedder = Rag::Embedder.new(api_key: nil)
    @document.document_chunks.create!(
      content: "Protocolo de incendio: evacuar por las escaleras.",
      page_number: 12, embedding: embedder.embed_one("Protocolo de incendio: evacuar por las escaleras.")
    )
  end

  test "streams the answer as Server-Sent Events when stream=true" do
    post api_v1_chats_query_url,
         params: { question: "¿Qué hago en caso de incendio?", document_ids: [ @document.id ], stream: true },
         headers: auth_headers(@tenant), as: :json

    assert_response :success
    assert_equal "text/event-stream", response.media_type
    assert_includes response.body, "event: token"
    assert_includes response.body, "event: done"
    assert_includes response.body, "sources"
  end

  test "still returns plain JSON when stream is absent" do
    post api_v1_chats_query_url,
         params: { question: "incendio", document_ids: [ @document.id ] },
         headers: auth_headers(@tenant), as: :json

    assert_response :success
    assert_equal "application/json", response.media_type
    assert JSON.parse(response.body).key?("answer")
  end
end
