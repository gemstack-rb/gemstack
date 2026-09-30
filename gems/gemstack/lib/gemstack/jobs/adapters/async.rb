# frozen_string_literal: true

module GemStack
  module Jobs
    module Adapters
      # An in-process thread pool with an in-memory schedule (retries and
      # `set(wait:)` work). Jobs are lost when the process exits, so it is
      # meant for development and apps without a database — use :postgres
      # or :sidekiq in production.
      class Async
        include AfterCommit

        Entry = Struct.new(:run_at, :sequence, :payload)

        def initialize(concurrency: Jobs.config.concurrency)
          @concurrency = concurrency
          @entries = []
          @mutex = Mutex.new
          @available = ConditionVariable.new
          @sequence = 0
          @running = 0
          @threads = nil
        end

        def enqueue(payload)
          id = SecureRandom.uuid
          after_commit { schedule(payload.merge("id" => id, "attempts" => 0), payload["run_at"] || Time.now) }
          id
        end

        # Blocks until no jobs are queued or running (mainly for tests).
        def drain(timeout: 10)
          deadline = monotonic + timeout
          sleep 0.01 until @mutex.synchronize { @entries.empty? && @running.zero? } || monotonic > deadline
        end

        def shutdown
          @mutex.synchronize do
            @stopping = true
            @available.broadcast
          end
          @threads&.each { |thread| thread.join(Jobs.config.shutdown_timeout) }
          @threads = nil
        end

        private

        def schedule(payload, run_at)
          worker_threads
          @mutex.synchronize do
            @sequence += 1
            @entries << Entry.new(run_at, @sequence, payload)
            @entries.sort_by! { |e| [e.run_at, e.payload["priority"] || 100, e.sequence] }
            @available.broadcast
          end
        end

        # Started lazily on the first job; shutdown joins them.
        def worker_threads
          @mutex.synchronize do
            @threads ||= Array.new(@concurrency) { Thread.new { work } } # rubocop:disable Naming/MemoizedInstanceVariableName
          end
        end

        def work
          loop do
            entry = next_entry or break
            outcome = Executor.execute(entry.payload)
            schedule(entry.payload.merge("attempts" => outcome.attempt), outcome.run_at) if outcome.status == :retry
          ensure
            @mutex.synchronize { @running -= 1 } if entry
          end
        end

        def next_entry
          @mutex.synchronize do
            loop do
              return nil if @stopping

              first = @entries.first
              if first && first.run_at <= Time.now
                @running += 1
                return @entries.shift
              end
              @available.wait(@mutex, first ? [first.run_at - Time.now, 0.01].max : nil)
            end
          end
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
