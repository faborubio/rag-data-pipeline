# Structured (JSON) request logging: one line per request, enriched with the
# request id, the authenticated tenant and the RAG metrics gathered per request
# (embedding/search latency, cache hits, sources). Disabled in tests for quiet output.
unless Rails.env.test?
  Rails.application.configure do
    config.lograge.enabled = true
    config.lograge.formatter = Lograge::Formatters::Json.new

    config.lograge.custom_options = lambda do |event|
      {
        ts: Time.now.utc.iso8601(3),
        request_id: Current.request_id,
        tenant_id: Current.tenant&.id
      }.merge(Current.rag).compact
    end
  end
end
