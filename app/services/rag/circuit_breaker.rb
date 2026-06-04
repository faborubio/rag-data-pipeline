module Rag
  # Minimal, thread-safe, process-local circuit breaker.
  # Protects the web/worker process from cascading failures when an external
  # AI API is down or rate-limiting (spec: Resiliencia Backend).
  class CircuitBreaker
    class OpenCircuitError < StandardError; end

    def initialize(name:, failure_threshold: 5, reset_timeout: 30)
      @name = name
      @failure_threshold = failure_threshold
      @reset_timeout = reset_timeout
      @mutex = Mutex.new
      @failures = 0
      @opened_at = nil
    end

    def run
      raise OpenCircuitError, "#{@name} circuit is open" if open?

      result = yield
      reset!
      result
    rescue OpenCircuitError
      raise
    rescue StandardError => e
      record_failure
      raise e
    end

    def open?
      @mutex.synchronize do
        return false if @opened_at.nil?

        if Time.now - @opened_at >= @reset_timeout
          # half-open: clear state and allow a trial request through
          @failures = 0
          @opened_at = nil
          false
        else
          true
        end
      end
    end

    private

    def record_failure
      @mutex.synchronize do
        @failures += 1
        @opened_at = Time.now if @failures >= @failure_threshold
      end
    end

    def reset!
      @mutex.synchronize do
        @failures = 0
        @opened_at = nil
      end
    end
  end
end
