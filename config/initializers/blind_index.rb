# BlindIndex master key for deterministic, searchable hashing of secrets.
# ENV-first (see config/initializers/lockbox.rb for the rationale).
BlindIndex.master_key =
  ENV["BLIND_INDEX_MASTER_KEY"] ||
  Rails.application.credentials.dig(:blind_index, :master_key)
