class AddContentHashToDocumentChunks < ActiveRecord::Migration[8.1]
  # Embedding idempotency: re-ingesting a document (or the eval runner re-running
  # the same PDFs) must not re-embed unchanged text and burn provider quota.
  # Reuse is keyed on the SHA256 of the content AND the provider that produced
  # the vector — embeddings from different providers live in different spaces and
  # must never be mixed.
  def up
    add_column :document_chunks, :content_hash, :string
    add_column :document_chunks, :embedding_provider, :string

    # Backfill the hash for existing rows so they can be reused on the next
    # ingest. encode(digest(...)) matches Ruby's Digest::SHA256.hexdigest exactly.
    # embedding_provider stays NULL (provenance unknown) on purpose, so these
    # rows are never reused until re-embedded by a known provider.
    execute <<~SQL
      UPDATE document_chunks
      SET content_hash = encode(public.digest(content, 'sha256'), 'hex')
      WHERE content_hash IS NULL
    SQL

    add_index :document_chunks, [ :content_hash, :embedding_provider ],
              name: "index_document_chunks_on_hash_and_provider"
  end

  def down
    remove_index :document_chunks, name: "index_document_chunks_on_hash_and_provider"
    remove_column :document_chunks, :embedding_provider
    remove_column :document_chunks, :content_hash
  end
end
