class CreateTenants < ActiveRecord::Migration[8.1]
  def change
    create_table :tenants, id: :uuid do |t|
      t.string :name, null: false
      # API key reference. Will be encrypted at rest (lockbox/blind_index) in a later task.
      t.string :api_key_id

      t.timestamps
    end
  end
end
