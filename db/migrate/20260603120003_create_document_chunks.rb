class CreateDocumentChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :document_chunks, id: :uuid do |t|
      t.references :document, type: :uuid, null: false, foreign_key: true, index: true
      t.text    :content, null: false
      # 1536 dimensions: OpenAI text-embedding-3-small (mandatory per spec)
      t.vector  :embedding, limit: 1536
      t.integer :page_number

      t.timestamps
    end

    # HNSW index for fast approximate nearest-neighbor search.
    # vector_cosine_ops matches the cosine-distance operator (<=>) used by the query endpoint.
    add_index :document_chunks, :embedding,
              using: :hnsw,
              opclass: :vector_cosine_ops,
              name: "index_document_chunks_on_embedding_hnsw"
  end
end
