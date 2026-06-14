module Rag
  # Minimal, thread-safe, process-local circuit breaker.
  # Protects the web/worker process from cascading failures when an external
  # AI API is down or rate-limiting (spec: Resiliencia Backend).
  #
  # States: closed -> (failures reach threshold) -> open -> (reset_timeout
  # elapsed) -> half-open -> (trial succeeds) -> closed, or (trial fails) -> open.
  # In half-open only ONE trial request is admitted; concurrent callers are
  # rejected so a recovering dependency is not stampeded.
  class CircuitBreaker
    class OpenCircuitError < StandardError; end

    def initialize(name:, failure_threshold: 5, reset_timeout: 30)
      @name = name
      @failure_threshold = failure_threshold
      @reset_timeout = reset_timeout
      @mutex = Mutex.new
      @state = :closed
      @failures = 0
      @opened_at = nil
    end

    def run
      admit!
      result = yield
      record_success
      result
    rescue OpenCircuitError
      raise
    rescue StandardError => e
      record_failure
      raise e
    end

    def open?
      @mutex.synchronize { @state == :open && !reset_due? }
    end

    private

    # Decides whether this call may proceed, transitioning open -> half-open for
    # the single trial. Raises OpenCircuitError otherwise.
    def admit!
      @mutex.synchronize do
        case @state
        when :open
          raise OpenCircuitError, "#{@name} circuit is open" unless reset_due?

          @state = :half_open # consume the lone trial slot
        when :half_open
          raise OpenCircuitError, "#{@name} circuit is open"
        end
      end
    end

    def reset_due?
      @opened_at && Time.now - @opened_at >= @reset_timeout
    end

    def record_success
      @mutex.synchronize do
        @state = :closed
        @failures = 0
        @opened_at = nil
      end
    end

    def record_failure
      @mutex.synchronize do
        @failures += 1
        if @state == :half_open || @failures >= @failure_threshold
          @state = :open
          @opened_at = Time.now
        end
      end
    end
  end
end
