require "prometheus/client/formats/text"

# Prometheus scrape endpoint (GET /metrics). Not tenant-authenticated so a
# scraper can reach it; restrict at the network layer, or set METRICS_TOKEN
# to require a bearer token.
class MetricsController < ActionController::API
  before_action :authorize_scrape

  def show
    render plain: Prometheus::Client::Formats::Text.marshal(AppMetrics::REGISTRY),
           content_type: Prometheus::Client::Formats::Text::CONTENT_TYPE
  end

  private

  def authorize_scrape
    token = ENV["METRICS_TOKEN"]
    return if token.blank? # open when no token is configured

    provided = request.headers["Authorization"].to_s.split(" ", 2).last.to_s
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(provided, token)
  end
end
