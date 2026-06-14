require "digest"

# Per-tenant (per-API-key) rate limiting.
module RateLimit
  # Requests allowed per `period` seconds, per API key. Tunable via ENV / tests.
  mattr_accessor :limit, default: Integer(ENV.fetch("RATE_LIMIT_PER_MINUTE", 60))
  mattr_accessor :period, default: 60
  # Coarse budget for UNAUTHENTICATED /api/ traffic, keyed by IP — caps API-key
  # brute-forcing, which the per-key throttle below cannot see.
  mattr_accessor :unauthenticated_ip_limit, default: Integer(ENV.fetch("UNAUTH_RATE_LIMIT_PER_MINUTE", 20))

  # Extracts the raw API key from an Authorization: Bearer or X-API-Key header.
  def self.api_key(req)
    authorization = req.get_header("HTTP_AUTHORIZATION").to_s
    return authorization.split(" ", 2).last if authorization.start_with?("Bearer ")

    req.get_header("HTTP_X_API_KEY").presence
  end
end

class Rack::Attack
  # Throttle authenticated API traffic, keyed by the caller's API key so each
  # tenant gets its own independent budget (the key is hashed, never stored).
  throttle("api/tenant", limit: ->(_req) { RateLimit.limit }, period: 60) do |req|
    next unless req.path.start_with?("/api/")

    key = RateLimit.api_key(req)
    Digest::SHA256.hexdigest(key) if key.present?
  end

  # Throttle UNAUTHENTICATED /api/ traffic by IP. Requests without a key never
  # match the per-key throttle, so without this an attacker could hammer the
  # auth endpoint trying keys with no limit at all.
  throttle("api/unauthenticated-ip", limit: ->(_req) { RateLimit.unauthenticated_ip_limit }, period: 60) do |req|
    req.ip if req.path.start_with?("/api/") && RateLimit.api_key(req).blank?
  end

  # JSON 429 response with a Retry-After hint.
  self.throttled_responder = lambda do |req|
    match = req.env["rack.attack.match_data"] || {}
    retry_after = (match[:period] || RateLimit.period).to_s
    headers = {
      "Content-Type" => "application/json",
      "Retry-After" => retry_after
    }
    [ 429, headers, [ { error: "rate limit exceeded, retry later" }.to_json ] ]
  end
end
