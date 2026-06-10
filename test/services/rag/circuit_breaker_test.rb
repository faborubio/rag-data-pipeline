require "test_helper"

class Rag::CircuitBreakerTest < ActiveSupport::TestCase
  test "returns the block result while closed" do
    breaker = Rag::CircuitBreaker.new(name: "t")
    assert_equal 42, breaker.run { 42 }
  end

  test "opens after reaching the failure threshold" do
    breaker = Rag::CircuitBreaker.new(name: "t", failure_threshold: 2, reset_timeout: 60)
    2.times { assert_raises(RuntimeError) { breaker.run { raise "boom" } } }

    assert breaker.open?
    assert_raises(Rag::CircuitBreaker::OpenCircuitError) { breaker.run { 1 } }
  end

  test "half-opens and allows a trial after the reset timeout" do
    breaker = Rag::CircuitBreaker.new(name: "t", failure_threshold: 1, reset_timeout: 0)
    assert_raises(RuntimeError) { breaker.run { raise "boom" } }

    # reset_timeout 0 -> immediately eligible for a trial request
    assert_equal 7, breaker.run { 7 }
    assert_not breaker.open?
  end
end
