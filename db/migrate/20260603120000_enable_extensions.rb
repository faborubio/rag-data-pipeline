class EnableExtensions < ActiveRecord::Migration[8.1]
  def change
    # pgcrypto -> gen_random_uuid() for UUID primary keys
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")
    # vector -> pgvector type + HNSW index support (the real extension name is "vector")
    enable_extension "vector" unless extension_enabled?("vector")
  end
end
