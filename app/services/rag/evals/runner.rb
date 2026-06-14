module Rag
  module Evals
    # RAG quality evals: ingests the golden corpus through the REAL pipeline
    # (PdfBuilder -> pdftotext -> chunk -> embed -> persist) under an ephemeral
    # tenant, runs every golden question through QueryService, and aggregates
    # retrieval/answer metrics. Same harness for both tiers: the lexical
    # fallback (CI, no API key) and live OpenAI (OPENAI_API_KEY set).
    class Runner
      # Aggregate minimums enforced by test/evals/rag_quality_test.rb and the
      # rag:evals task. Calibrated against the hybrid-retrieval baseline on the
      # deterministic fallback tier (observed: recall 0.958 / MRR 0.927 /
      # keywords 0.917 — the only remaining miss is rh-008, which needs true
      # semantic embeddings). Thresholds sit ~6-12 points below to lock in the
      # hybrid gain: a regression to vector-only (recall 0.917 / MRR 0.826 /
      # keywords 0.750) trips the keyword gate.
      THRESHOLDS = { recall_at_k: 0.90, mrr: 0.85, keyword_presence: 0.80 }.freeze

      Row = Struct.new(:id, :question, :document, :rank, :recall, :reciprocal_rank,
                       :keyword_presence, :answer, keyword_init: true)

      Report = Struct.new(:rows, :recall_at_k, :mrr, :keyword_presence, :k, keyword_init: true) do
        def pass?
          recall_at_k >= THRESHOLDS[:recall_at_k] &&
            mrr >= THRESHOLDS[:mrr] &&
            keyword_presence >= THRESHOLDS[:keyword_presence]
        end

        def failures
          rows.select { |row| row.recall.zero? || row.keyword_presence < 1.0 }
        end
      end

      def initialize(golden_set: GoldenSet.load, query_service: Rag::QueryService.new,
                     ingestor: Rag::Ingestor.new, k: Rag::QueryService::TOP_K)
        @golden_set = golden_set
        @query_service = query_service
        @ingestor = ingestor
        @k = k
      end

      def run
        original_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::NullStore.new
        tenant = Tenant.create!(name: "evals-#{SecureRandom.hex(4)}", api_key: SecureRandom.hex(16))
        documents = ingest_corpus(tenant)
        rows = @golden_set.questions.map { |q| evaluate(tenant, documents, q) }
        build_report(rows)
      ensure
        Rails.cache = original_cache
      end

      private

      def ingest_corpus(tenant)
        dir = Rails.root.join("tmp/evals")
        FileUtils.mkdir_p(dir)
        @golden_set.corpus.to_h do |name, pages|
          path = dir.join("#{name}.pdf")
          PdfBuilder.write(path, pages)
          document = tenant.documents.create!(filename: "#{name}.pdf", status: :completed)
          @ingestor.call(document, path.to_s)
          [ name, document ]
        ensure
          FileUtils.rm_f(path)
        end
      end

      def evaluate(tenant, documents, question)
        document = documents.fetch(question.document)
        result = @query_service.call(tenant: tenant, question: question.question,
                                     document_ids: documents.values.map(&:id))
        target = { document_id: document.id, expected_pages: question.expected_pages }

        Row.new(
          id: question.id,
          question: question.question,
          document: question.document,
          rank: Metrics.relevant_rank(result.sources, **target),
          recall: Metrics.recall_at_k(result.sources, k: @k, **target),
          reciprocal_rank: Metrics.reciprocal_rank(result.sources, **target),
          keyword_presence: Metrics.keyword_presence(result.answer, question.expected_keywords),
          answer: result.answer
        )
      end

      def build_report(rows)
        Report.new(
          rows: rows,
          recall_at_k: average(rows.map(&:recall)),
          mrr: average(rows.map(&:reciprocal_rank)),
          keyword_presence: average(rows.map(&:keyword_presence)),
          k: @k
        )
      end

      def average(values)
        values.sum.fdiv(values.size)
      end
    end
  end
end
