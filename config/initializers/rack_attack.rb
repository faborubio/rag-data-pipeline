require "digest"

# Per-tenant (per-API-key) rate limiting.
module RateLimit
  # Requests allowed per `period` seconds, per API key. Tunable via ENV / tests.
  mattr_accessor :limit, default: Integer(ENV.fetch("RATE_LIMIT_PER_MINUTE", 60))
  mattr_accessor :period, default: 60
end

class Rack::Attack
  # Throttle authenticated API traffic, keyed by the caller's API key so each
  # tenant gets its own independent budget (the key is hashed, never stored).
  throttle("api/tenant", limit: ->(_req) { RateLimit.limit }, period: 60) do |req|
    next unless req.path.start_with?("/api/")

    authorization = req.get_header("HTTP_AUTHORIZATION").to_s
    key = if authorization.start_with?("Bearer ")
            authorization.split(" ", 2).last
    else
            req.get_header("HTTP_X_API_KEY")
    end

    Digest::SHA256.hexdigest(key) if key.present?
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
