class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    # citext gives case-insensitive, unique emails at the DB level.
    enable_extension "citext" unless extension_enabled?("citext")

    create_table :users, id: :uuid do |t|
      t.citext :email, null: false
      t.string :password_digest, null: false
      # Each user owns one writable tenant — their private, isolated workspace.
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: true
      t.timestamps
    end
    add_index :users, :email, unique: true
  end
end
