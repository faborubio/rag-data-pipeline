class CreateQueryLogs < ActiveRecord::Migration[8.1]
  # Append-only analytics: one row per query so a tenant can see what's asked
  # most and which questions the corpus couldn't answer (abstentions = content
  # gaps). Kept deliberately minimal — no answer text stored.
  def change
    create_table :query_logs, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.text     :question, null: false
      t.boolean  :answered, null: false, default: true
      t.float    :rerank_score # null on a cache hit (retrieval was skipped)
      t.boolean  :cache_hit, null: false, default: false
      t.integer  :sources_count, null: false, default: 0
      t.integer  :latency_ms

      t.datetime :created_at, null: false
    end

    add_index :query_logs, [ :tenant_id, :created_at ]
  end
end
