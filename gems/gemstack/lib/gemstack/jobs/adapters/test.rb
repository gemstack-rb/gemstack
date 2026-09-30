# frozen_string_literal: true

module GemStack
  module Jobs
    module Adapters
      # Records jobs instead of running them (the default in tests). See
      # GemStack::Jobs::Testing for assertions and perform_enqueued_jobs.
      class Test
        attr_reader :enqueued, :performed

        def initialize
          @enqueued = []
          @performed = []
          @mutex = Mutex.new
          @sequence = 0
        end

        def enqueue(payload)
          @mutex.synchronize do
            @sequence += 1
            @enqueued << payload.merge("id" => @sequence, "attempts" => 0)
            @sequence
          end
        end

        # Runs enqueued jobs (and jobs they enqueue) until none are left, or
        # only those matching `only`. An error a job raises is re-raised (unless
        # the job discards it), so failing jobs fail the test. Returns the outcomes.
        def perform_enqueued(only: nil, except_ids: [])
          names = only && Array(only).map(&:to_s)
          outcomes = []
          loop do
            payload = @mutex.synchronize do
              index = @enqueued.index do |p|
                (names.nil? || names.include?(p["job_class"])) && !except_ids.include?(p["id"])
              end
              index && @enqueued.delete_at(index)
            end
            break unless payload

            outcome = Executor.execute(payload)
            raise outcome.error if outcome.error && outcome.status != :discarded

            @performed << payload
            outcomes << outcome
          end
          outcomes
        end

        def clear
          @mutex.synchronize do
            @enqueued.clear
            @performed.clear
          end
        end
      end
    end
  end
end
