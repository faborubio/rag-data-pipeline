# BlindIndex master key for deterministic, searchable hashing of secrets.
BlindIndex.master_key =
  Rails.application.credentials.dig(:blind_index, :master_key) ||
  ENV["BLIND_INDEX_MASTER_KEY"]
