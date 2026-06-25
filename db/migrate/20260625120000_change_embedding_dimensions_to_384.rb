class ChangeEmbeddingDimensionsTo384 < ActiveRecord::Migration[8.1]
  # The default embedder is now the local ONNX e5 model (384-d) instead of Gemini
  # (1536-d). Different model => different vector space, so existing embeddings are
  # invalid and must be re-embedded (rake rag:reembed) after this runs; clearing
  # them first lets the column type change without an impossible 1536->384 cast.
  def up = rebuild_embedding_column(384)
  def down = rebuild_embedding_column(1536)

  private

  def rebuild_embedding_column(dims)
    remove_index :document_chunks, name: "index_document_chunks_on_embedding_hnsw"
    execute "UPDATE document_chunks SET embedding = NULL"
    change_column :document_chunks, :embedding, :vector, limit: dims
    add_index :document_chunks, :embedding,
              using: :hnsw, opclass: :vector_cosine_ops,
              name: "index_document_chunks_on_embedding_hnsw"
  end
end
