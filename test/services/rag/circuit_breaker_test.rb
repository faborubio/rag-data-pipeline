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

  test "a failed trial re-opens the circuit" do
    breaker = Rag::CircuitBreaker.new(name: "t", failure_threshold: 1, reset_timeout: 0.05)
    assert_raises(RuntimeError) { breaker.run { raise "boom" } }
    assert breaker.open?, "open during the cooldown window"

    sleep 0.06 # cooldown elapses -> the next call is the half-open trial
    assert_raises(RuntimeError) { breaker.run { raise "still down" } }
    assert breaker.open?, "a failed trial should send the breaker straight back to open"
  end

  test "half-open admits only one trial request at a time" do
    breaker = Rag::CircuitBreaker.new(name: "t", failure_threshold: 1, reset_timeout: 0)
    assert_raises(RuntimeError) { breaker.run { raise "boom" } }

    # First caller enters the trial and blocks; a second concurrent caller must
    # be rejected instead of also hitting the recovering dependency.
    entered = Queue.new
    release = Queue.new
    trial = Thread.new do
      breaker.run do
        entered << true
        release.pop
        :ok
      end
    end

    entered.pop # ensure the trial is in-flight (state is half-open)
    assert_raises(Rag::CircuitBreaker::OpenCircuitError) { breaker.run { 1 } }
    release << true
    assert_equal :ok, trial.value
  end
end
