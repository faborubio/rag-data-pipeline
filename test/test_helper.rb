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
      objects = {}
      objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
      objects[3] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"

      page_ids = []
      next_id = 4
      page_texts.each do |text|
        page_id = next_id
        content_id = next_id + 1
        next_id += 2
        page_ids << page_id
        safe = text.to_s.gsub("(", " ").gsub(")", " ")
        stream = "BT /F1 14 Tf 72 720 Td (#{safe}) Tj ET"
        objects[page_id] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
                           "/Contents #{content_id} 0 R /Resources << /Font << /F1 3 0 R >> >> >>"
        objects[content_id] = "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"
      end
      objects[2] = "<< /Type /Pages /Kids [#{page_ids.map { |i| "#{i} 0 R" }.join(' ')}] " \
                   "/Count #{page_texts.size} >>"

      header = "%PDF-1.4\n"
      ids = objects.keys.sort
      body = +""
      offsets = {}
      pos = header.bytesize
      ids.each do |id|
        offsets[id] = pos
        chunk = "#{id} 0 obj\n#{objects[id]}\nendobj\n"
        body << chunk
        pos += chunk.bytesize
      end
      max_id = ids.max
      xref_pos = header.bytesize + body.bytesize
      xref = +"xref\n0 #{max_id + 1}\n0000000000 65535 f \n"
      (1..max_id).each do |id|
        xref << (offsets[id] ? format("%010d 00000 n \n", offsets[id]) : "0000000000 65535 f \n")
      end
      trailer = "trailer\n<< /Size #{max_id + 1} /Root 1 0 R >>\nstartxref\n#{xref_pos}\n%%EOF\n"
      File.binwrite(path, header + body + xref + trailer)
      path
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
