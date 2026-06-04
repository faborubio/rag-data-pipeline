class CreateDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :documents, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: true
      t.string  :filename, null: false
      # enum status: processing(0), completed(1), failed(2)
      t.integer :status,   null: false, default: 0
      t.jsonb   :metadata, null: false, default: {}

      t.timestamps
    end
  end
end
