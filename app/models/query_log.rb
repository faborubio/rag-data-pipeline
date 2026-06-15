class QueryLog < ApplicationRecord
  belongs_to :tenant

  scope :answered, -> { where(answered: true) }
  scope :abstained, -> { where(answered: false) }

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
