require "test_helper"

class QueryLogTest < ActiveSupport::TestCase
  setup { @tenant = Tenant.create!(name: "Acme") }

  test "sanitize_question truncates to the configured max length" do
    long = "a" * (QueryLog.question_max_length + 50)
    assert_equal QueryLog.question_max_length, QueryLog.sanitize_question(long).length
  end

  test "sanitize_question redacts when text storage is disabled" do
    original = QueryLog.store_question_text
    QueryLog.store_question_text = false
    assert_equal QueryLog::REDACTED, QueryLog.sanitize_question("¿dato sensible?")
  ensure
    QueryLog.store_question_text = original
  end

  test "purge_expired deletes rows past the retention window and keeps recent ones" do
    skip "retention disabled (RETENTION_DAYS=0)" unless QueryLog::RETENTION_DAYS.positive?

    old = QueryLog.create!(tenant: @tenant, question: "vieja", answered: true)
    old.update_column(:created_at, (QueryLog::RETENTION_DAYS + 1).days.ago)
    recent = QueryLog.create!(tenant: @tenant, question: "reciente", answered: true)

    assert_equal 1, QueryLog.purge_expired
    assert_not QueryLog.exists?(old.id), "an expired row should be purged"
    assert QueryLog.exists?(recent.id), "a recent row should be kept"
  end
end
