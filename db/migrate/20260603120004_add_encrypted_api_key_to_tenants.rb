class AddEncryptedApiKeyToTenants < ActiveRecord::Migration[8.1]
  def change
    # Lockbox stores the encrypted secret API key here (attribute :api_key)
    add_column :tenants, :api_key_ciphertext, :text
    # blind_index allows looking the tenant up by raw API key without decrypting
    add_column :tenants, :api_key_bidx, :string
    add_index  :tenants, :api_key_bidx, unique: true
  end
end
