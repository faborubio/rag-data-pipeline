class QueryLog < ApplicationRecord
  belongs_to :tenant

  # Privacy/retention knobs. Questions can be user-typed free text (potentially
  # PII), so: bound how long rows live, cap the stored length, and allow turning
  # off text storage entirely (analytics still count volume/answer-rate, just
  # without the question text). Class accessors (not constants) so they're easy to
  # flip in tests; defaults come from ENV at boot.
  REDACTED = "[redacted]".freeze
  RETENTION_DAYS = (ENV["QUERY_LOG_RETENTION_DAYS"] || 90).to_i

  class << self
    attr_accessor :question_max_length, :store_question_text
  end
  self.question_max_length = (ENV["QUERY_LOG_QUESTION_MAX_LENGTH"] || 500).to_i
  self.store_question_text = ENV["QUERY_LOG_STORE_QUESTION"] != "0"

  # User feedback on the answer: 1 = 👍, -1 = 👎, nil = no vote.
  validates :rating, inclusion: { in: [ -1, 1 ] }, allow_nil: true

  scope :answered, -> { where(answered: true) }
  scope :abstained, -> { where(answered: false) }
  scope :expired, -> { where(created_at: ...RETENTION_DAYS.days.ago) if RETENTION_DAYS.positive? }

  # What actually gets persisted for a question: redacted when text storage is
  # off, otherwise truncated to bound row size (and stray PII).
  def self.sanitize_question(text)
    return REDACTED unless store_question_text

    text.to_s[0, question_max_length]
  end

  # Delete rows past the retention window. Wired to `rake rag:purge_query_logs`.
  def self.purge_expired
    return 0 unless RETENTION_DAYS.positive?

    expired.delete_all
  end

  # Most-asked questions for a tenant: [{ question:, count: }] best-first.
  def self.top_questions(tenant, limit: 10)
    frequency(where(tenant: tenant), limit)
  end

  # Questions the corpus couldn't answer (abstentions) — i.e. content gaps.
  def self.content_gaps(tenant, limit: 10)
    frequency(where(tenant: tenant).abstained, limit)
  end

  def self.frequency(relation, limit)
    relation.group(:question)
            .order(Arel.sql("COUNT(*) DESC"))
            .limit(limit)
            .count
            .map { |question, count| { question: question, count: count } }
  end
end
