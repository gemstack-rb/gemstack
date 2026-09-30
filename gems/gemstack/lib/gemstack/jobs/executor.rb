# frozen_string_literal: true

module GemStack
  module Jobs
    # Runs one job payload and decides what happens next. Shared by every
    # adapter, so retries, discards, failures and instrumentation behave the
    # same everywhere.
    #
    # Returns an Outcome: :performed, :retry (with run_at), :discarded or :failed.
    module Executor
      Outcome = Struct.new(:status, :error, :run_at, :attempt, keyword_init: true)

      module_function

      # payload: "job_class", "args", "queue", "attempts" (runs so far), "id".
      def execute(payload)
        attempt = Integer(payload["attempts"] || 0) + 1
        fields = { job_class: payload["job_class"], job_id: payload["id"], queue: payload["queue"], attempt: attempt }
        job_class = resolve(payload["job_class"])
        started = monotonic
        run(job_class, payload, attempt)
        Jobs.instrument(:performed, **fields, duration_ms: elapsed(started))
        Outcome.new(status: :performed, attempt: attempt)
      rescue UnknownJob => e
        Jobs.instrument(:failed, **fields, error: e)
        Outcome.new(status: :failed, error: e, attempt: attempt)
      rescue StandardError => e
        failure(job_class, e, attempt, fields.merge(duration_ms: elapsed(started)))
      end

      def run(job_class, payload, attempt)
        job = job_class.new
        job.job_id = payload["id"]
        job.attempt = attempt
        job.perform(*Arguments.load(payload["args"] || []))
      end

      def failure(job_class, error, attempt, fields)
        if job_class.discard?(error)
          Jobs.instrument(:discarded, **fields, error: error)
          return Outcome.new(status: :discarded, error: error, attempt: attempt)
        end

        _max, wait = job_class.retry_decision(error, attempt)
        if wait
          run_at = Time.now + wait
          Jobs.instrument(:retried, **fields, error: error, run_at: run_at)
          Outcome.new(status: :retry, error: error, run_at: run_at, attempt: attempt)
        else
          Jobs.instrument(:failed, **fields, error: error)
          Outcome.new(status: :failed, error: error, attempt: attempt)
        end
      end

      # Only GemStack::Job subclasses can run — a queue row naming another
      # constant is never instantiated.
      def resolve(name)
        klass = Object.const_get(name.to_s)
        raise UnknownJob, "#{name} is not a GemStack::Job" unless klass.is_a?(Class) && klass < Job

        klass
      rescue NameError
        raise UnknownJob, "unknown job class #{name.inspect}"
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def elapsed(started) = started && ((monotonic - started) * 1000).round(2)
    end
  end
end
