class AddRolesAndKeysToUsers < ActiveRecord::Migration[8.1]
  def change
    # Role gates permissions (admin curates / visitor reads); the per-user API key
    # (encrypted + blind index, mirroring tenants) lets two accounts share one
    # corpus tenant while the request still resolves to a specific user + role.
    add_column :users, :role, :string, null: false, default: "visitor"
    add_column :users, :api_key_id, :string
    add_column :users, :api_key_ciphertext, :text
    add_column :users, :api_key_bidx, :string
    add_index :users, :api_key_bidx, unique: true
  end
end
