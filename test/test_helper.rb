ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Serial execution: the pgvector/HNSW test schema is simpler to maintain
    # across a single test database than across parallel worker copies.
    parallelize(workers: 1)

    # No fixtures: encrypted (Lockbox) and vector columns are best created
    # through the models inside each test's setup.

    # A normalized 1536-dim vector for embedding assertions.
    def sample_vector(seed = 1)
      rng = Random.new(seed)
      vector = Array.new(Rag::EMBEDDING_DIMENSIONS) { rng.rand(-1.0..1.0) }
      norm = Math.sqrt(vector.sum { |x| x * x })
      vector.map { |x| x / norm }
    end

    # Writes a minimal, valid multi-page PDF (one text line per page) to `path`.
    def build_pdf(path, page_texts)
      Rag::Evals::PdfBuilder.write(path, page_texts)
    end
  end
end

module ActionDispatch
  class IntegrationTest
    # Authorization header for a given tenant's raw API key.
    def auth_headers(tenant)
      { "Authorization" => "Bearer #{tenant.api_key}" }
    end
  end
end
