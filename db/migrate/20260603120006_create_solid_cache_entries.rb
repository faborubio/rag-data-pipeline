class CreateSolidCacheEntries < ActiveRecord::Migration[8.1]
  # Solid Cache table in the primary database (single-DB setup for development).
  # In production it lives in a dedicated `cache` database (db/cache_structure.sql).
  def change
    create_table :solid_cache_entries do |t|
      t.binary   :key, null: false
      t.binary   :value, null: false
      t.datetime :created_at, null: false
      t.bigint   :key_hash, null: false
      t.integer  :byte_size, null: false
      t.index :byte_size, name: "index_solid_cache_entries_on_byte_size"
      t.index :key_hash, unique: true, name: "index_solid_cache_entries_on_key_hash"
      t.index %w[key_hash byte_size], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    end
  end
end
