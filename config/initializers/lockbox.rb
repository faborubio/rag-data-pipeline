# Lockbox master key for encryption at rest.
# Prefer ENV (container deploys / CI) and fall back to Rails encrypted
# credentials. ENV-first avoids decrypting credentials when no master key
# is present (e.g. CI), which would otherwise raise at boot.
Lockbox.master_key =
  ENV["LOCKBOX_MASTER_KEY"] ||
  Rails.application.credentials.dig(:lockbox, :master_key)
