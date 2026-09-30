# frozen_string_literal: true

require "socket"

module GemStack
  module Jobs
    # Processes jobs from the PostgreSQL queue (`gemstack jobs`).
    #
    # - `concurrency` threads each claim and run one job at a time.
    # - A listener thread LISTENs for NOTIFY and wakes idle threads at once;
    #   idle threads also re-check every poll_interval.
    # - A reaper releases jobs whose lock is older than lock_timeout (a worker
    #   crashed mid-job), so they run again (at-least-once delivery).
    # - stop (SIGINT/SIGTERM) lets running jobs finish for shutdown_timeout,
    #   then releases the rest back to the queue.
    #
    # Needs concurrency + 2 database connections (the CLI sizes the pool).
    class Worker
      attr_reader :id

      def initialize(store: Adapters::Database.new, queues: Jobs.config.queues, concurrency: Jobs.config.concurrency,
                     poll_interval: Jobs.config.poll_interval, lock_timeout: Jobs.config.lock_timeout,
                     shutdown_timeout: Jobs.config.shutdown_timeout)
        @store = store
        @queues = Array(queues).map(&:to_s)
        @concurrency = concurrency
        @poll_interval = poll_interval || (store.respond_to?(:postgres?) && store.postgres? ? 5 : 1)
        @lock_timeout = lock_timeout
        @shutdown_timeout = shutdown_timeout
        @id = "#{Socket.gethostname}:#{Process.pid}:#{SecureRandom.hex(3)}"
        @mutex = Mutex.new
        @wakeup = ConditionVariable.new
        @running = false
        @threads = []
      end

      def running? = @running

      # Starts the threads and returns immediately.
      def start
        @running = true
        GemStack.logger.info("jobs worker started", worker: @id, queues: @queues.join(","), concurrency: @concurrency)
        @threads = Array.new(@concurrency) { |i| Thread.new { work_loop(i) } }
        @listener = Thread.new { listen_loop } if @store.respond_to?(:postgres?) && @store.postgres?
        @reaper = Thread.new { reap_loop }
        self
      end

      # Blocks until SIGINT/SIGTERM, then shuts down gracefully.
      def run
        %w[INT TERM].each { |signal| trap(signal) { @running = false } }
        start
        sleep 0.2 while @running
        shutdown
      end

      def stop
        @running = false
        wake
      end

      def shutdown
        stop
        deadline = monotonic + @shutdown_timeout
        @threads.each { |thread| thread.join([deadline - monotonic, 0].max) }
        unfinished = @threads.count(&:alive?)
        @threads.each(&:kill)
        released = @store.release(@id)
        [@listener, @reaper].compact.each { |thread| thread.kill.join(1) }
        GemStack.logger.info("jobs worker stopped", worker: @id, released: released, unfinished: unfinished)
      end

      # Wakes idle threads (NOTIFY arrived, or shutting down).
      def wake = @mutex.synchronize { @wakeup.broadcast }

      # Runs one job if one is ready. Returns the outcome, or nil when idle.
      def work_once
        payload = @store.claim(@queues, @id) or return nil

        outcome = Executor.execute(payload)
        settle(payload, outcome)
        outcome
      end

      private

      def work_loop(_index)
        while @running
          begin
            idle(@poll_interval) unless work_once
          rescue Sequel::DatabaseConnectionError, Sequel::PoolTimeout => e
            GemStack.logger.warn("jobs worker: database unavailable, retrying", error: e.message)
            idle(@poll_interval)
          rescue StandardError => e # a bug in the worker itself; keep the thread alive
            GemStack.logger.error("jobs worker error", error: e, backtrace: Array(e.backtrace).first(10))
            idle(@poll_interval)
          end
        end
      end

      def settle(payload, outcome)
        case outcome.status
        when :performed, :discarded then @store.complete(payload["id"])
        when :retry
          @store.reschedule(payload["id"], run_at: outcome.run_at, attempts: outcome.attempt, error: outcome.error)
        when :failed then @store.fail(payload["id"], attempts: outcome.attempt, error: outcome.error)
        end
      end

      def idle(seconds)
        @mutex.synchronize { @wakeup.wait(@mutex, seconds) if @running }
      end

      def listen_loop
        @store.db.listen(Adapters::Database::CHANNEL, loop: ->(_conn) { throw :stop unless @running },
                                                      timeout: @poll_interval) { wake }
      rescue Sequel::DatabaseConnectionError => e
        GemStack.logger.warn("jobs worker: LISTEN failed, falling back to polling", error: e.message)
      end

      def reap_loop
        interval = [@lock_timeout / 4.0, 1].max
        while @running
          begin
            released = @store.release_stale(@lock_timeout)
            GemStack.logger.warn("jobs: released stale locks", count: released) if released.positive?
          rescue Sequel::Error => e
            GemStack.logger.warn("jobs reaper error", error: e.message)
          end
          sleep interval
        end
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
