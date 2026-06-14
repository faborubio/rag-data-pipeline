class AddReadOnlyToTenants < ActiveRecord::Migration[8.1]
  # Read-only tenants (e.g. the public demo) can query but never ingest, so a
  # shared public API key cannot be used to pollute the corpus.
  def change
    add_column :tenants, :read_only, :boolean, default: false, null: false
  end
end
