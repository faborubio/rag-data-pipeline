module Rag
  module Evals
    # Loads and validates the versioned golden dataset (config/evals/golden_set.yml):
    # a synthetic corpus of "manuals" plus questions with expected pages/keywords.
    class GoldenSet
      DEFAULT_PATH = "config/evals/golden_set.yml".freeze

      Question = Struct.new(:id, :document, :question, :expected_pages, :expected_keywords,
                            keyword_init: true)

      class InvalidError < StandardError; end

      # corpus: { "manual_seguridad" => ["page 1 text", ...] }
      attr_reader :corpus, :questions

      def self.load(path = Rails.root.join(DEFAULT_PATH))
        data = YAML.safe_load_file(path)
        new(data)
      end

      def initialize(data)
        @corpus = (data.fetch("corpus") { raise InvalidError, "missing corpus" })
                  .transform_values { |manual| manual.fetch("pages") }
        @questions = data.fetch("questions") { raise InvalidError, "missing questions" }
                         .map { |q| build_question(q) }
        validate!
      end

      private

      def build_question(raw)
        Question.new(
          id: raw.fetch("id"),
          document: raw.fetch("document"),
          question: raw.fetch("question"),
          expected_pages: Array(raw.fetch("expected_pages")),
          expected_keywords: Array(raw.fetch("expected_keywords"))
        )
      end

      def validate!
        questions.each do |q|
          pages = corpus[q.document] or
            raise InvalidError, "#{q.id}: unknown document #{q.document.inspect}"
          q.expected_pages.each do |page|
            unless page.between?(1, pages.size)
              raise InvalidError, "#{q.id}: page #{page} out of range for #{q.document} (1..#{pages.size})"
            end
          end
          raise InvalidError, "#{q.id}: expected_keywords must not be empty" if q.expected_keywords.empty?
        end
        dup_ids = questions.map(&:id).tally.select { |_, n| n > 1 }.keys
        raise InvalidError, "duplicate question ids: #{dup_ids.join(', ')}" if dup_ids.any?
      end
    end
  end
end
