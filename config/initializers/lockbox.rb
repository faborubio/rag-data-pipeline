# Lockbox master key for encryption at rest.
# Prefer Rails encrypted credentials; fall back to ENV for container deploys.
Lockbox.master_key =
  Rails.application.credentials.dig(:lockbox, :master_key) ||
  ENV["LOCKBOX_MASTER_KEY"]
