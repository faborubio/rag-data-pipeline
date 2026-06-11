require "opentelemetry/sdk"
require "opentelemetry/instrumentation/all"

# Distributed tracing with OpenTelemetry.
#
# `use_all` enables auto-instrumentation for Rack, Action Pack, Active Record
# (PostgreSQL / pgvector), Net::HTTP (the OpenAI calls) and Active Job — so a
# single trace follows a request across the synchronous Read Path AND the async
# ingestion job, with our own `rag.*` spans (see Rag.tracer) nested inside.
#
# The exporter is chosen by environment so nothing extra is needed to run locally:
#   * OTEL_EXPORTER_OTLP_ENDPOINT set -> batched OTLP to that collector/backend.
#   * development                     -> human-readable console exporter.
#   * test                            -> in-memory exporter (asserted by the suite).
#   * production without an endpoint  -> spans are dropped; just set the env var
#                                        to light up Jaeger/Grafana/Honeycomb.
module Tracing
  OTLP_ENDPOINT = ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].presence

  # Exposed so the test suite can read back the spans we emit.
  TEST_EXPORTER = (OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new if Rails.env.test?)

  def self.span_processor
    if OTLP_ENDPOINT
      require "opentelemetry/exporter/otlp"
      OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
        OpenTelemetry::Exporter::OTLP::Exporter.new
      )
    elsif Rails.env.development?
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(
        OpenTelemetry::SDK::Trace::Export::ConsoleSpanExporter.new
      )
    elsif Rails.env.test?
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(TEST_EXPORTER)
    end
  end
end

# We add span processors explicitly below, so stop the SDK from also wiring an
# OTLP exporter to localhost (which would log connection errors in production).
ENV["OTEL_TRACES_EXPORTER"] = "none"

OpenTelemetry::SDK.configure do |c|
  c.service_name = "rag-data-pipeline"
  c.service_version = ENV["APP_VERSION"].presence || "dev"
  c.use_all
  if (processor = Tracing.span_processor)
    c.add_span_processor(processor)
  end
end
