class AddFullTextSearchToDocumentChunks < ActiveRecord::Migration[8.1]
  # Spanish full-text search over chunk content, accent-insensitive. unaccent()
  # is not IMMUTABLE (its dictionary is configurable), so it cannot be used in
  # an expression index directly — the standard workaround is an immutable
  # wrapper pinned to the public.unaccent dictionary.
  def up
    enable_extension "unaccent" unless extension_enabled?("unaccent")

    execute <<~SQL
      CREATE OR REPLACE FUNCTION public.immutable_unaccent(text)
      RETURNS text AS $$
        SELECT public.unaccent('public.unaccent', $1)
      $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
    SQL

    execute <<~SQL
      CREATE INDEX index_document_chunks_on_content_fts
      ON document_chunks
      USING gin (to_tsvector('spanish', immutable_unaccent(content)));
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS index_document_chunks_on_content_fts"
    execute "DROP FUNCTION IF EXISTS public.immutable_unaccent(text)"
    disable_extension "unaccent" if extension_enabled?("unaccent")
  end
end
