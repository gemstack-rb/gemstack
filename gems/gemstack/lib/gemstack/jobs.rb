# frozen_string_literal: true

require "json"
require "securerandom"
require "gemstack/core"

module GemStack
  # Background jobs (ARCHITECTURE §9).
  #
  #   class SendWelcomeEmail < GemStack::Job
  #     queue :mailers
  #     retry_on Net::ReadTimeout, attempts: 5
  #     def perform(user_id) = Mailer.welcome(User.find(user_id))
  #   end
  #
  #   SendWelcomeEmail.perform_later(user.id)
  #   SendWelcomeEmail.set(wait: 600).perform_later(user.id)
  #
  # Work is only ever asynchronous when you ask for it with perform_later.
  # Delivery is at-least-once: make perform idempotent.
  module Jobs
    class Config < Settings
      # :database (default with gemstack/db loaded: the app's PostgreSQL, MySQL or
      # SQLite; :postgres is an alias), :async (in-process threads),
      # :inline (run immediately), :test (record only; default in tests),
      # :sidekiq, or an adapter object responding to #enqueue(payload).
      setting :adapter, default: lambda {
        if GemStack.env.test? then :test
        elsif defined?(GemStack::DB) then :database
        else :async
        end
      }
      setting :default_queue, default: "default"
      setting :default_priority, default: 100 # lower runs first
      setting :default_max_attempts, default: 10
      # Worker settings (`gemstack jobs`).
      setting :queues, default: -> { ENV.fetch("GEMSTACK_JOB_QUEUES", "*").split(",").map(&:strip) }
      setting :concurrency, default: -> { Integer(ENV.fetch("GEMSTACK_JOB_CONCURRENCY", 5)) }
      # Seconds between polls. PostgreSQL NOTIFY wakes workers instantly, so
      # there polling is only a safety net (5 s); MySQL and SQLite rely on it (1 s).
      setting :poll_interval, default: nil
      # A job locked longer than this is assumed abandoned (worker crashed) and is released.
      # Jobs that legitimately run longer must raise it.
      setting :lock_timeout, default: 30 * 60
      # How long a stopping worker waits for running jobs before releasing them.
      setting :shutdown_timeout, default: 25
      setting :table, default: :gemstack_jobs
      # Keep exhausted jobs (failed_at set) for inspection and `gemstack jobs:retry`.
      setting :keep_failed, default: true
    end

    autoload :Worker, "gemstack/jobs/worker"
    autoload :Testing, "gemstack/jobs/testing"

    # Raised for arguments that can't round-trip through JSON.
    class SerializationError < Error; end

    # A job's name didn't resolve to a GemStack::Job subclass when it ran.
    class UnknownJob < Error; end

    Event = Struct.new(:name, :job_class, :job_id, :queue, :attempt, :duration_ms, :error, :run_at, keyword_init: true)

    @subscribers = Hash.new { |hash, key| hash[key] = [] }
    @mutex = Mutex.new

    class << self
      def config = GemStack.config.jobs

      def adapter
        @adapter || @mutex.synchronize { @adapter ||= build_adapter(config.adapter) }
      end

      attr_writer :adapter

      def build_adapter(setting)
        case setting
        when :database, "database", :postgres, "postgres" then Adapters::Database.new
        when :async, "async" then Adapters::Async.new
        when :inline, "inline" then Adapters::Inline.new
        when :test, "test" then Adapters::Test.new
        when :sidekiq, "sidekiq" then Adapters::Sidekiq.new
        else
          raise ConfigurationError, "a job adapter must respond to #enqueue" unless setting.respond_to?(:enqueue)

          setting
        end
      end

      # True when jobs are rows in the application's database (and need a worker).
      def database_queue?(setting = config.adapter) = %w[database postgres].include?(setting.to_s)

      # Instrumentation for metrics/monitoring:
      #   GemStack::Jobs.subscribe(:failed) { |event| Sentry.capture_message(...) }
      # Events: :enqueued, :performed, :retried, :failed, :discarded.
      def subscribe(name = :all, &block)
        @mutex.synchronize { @subscribers[name.to_sym] << block }
        block
      end

      def unsubscribe(block)
        @mutex.synchronize { @subscribers.each_value { |list| list.delete(block) } }
      end

      def instrument(name, **fields)
        event = Event.new(name: name, **fields)
        log(event)
        (@subscribers[name] + @subscribers[:all]).each do |subscriber|
          subscriber.call(event)
        rescue StandardError => e
          GemStack.logger.error("job subscriber failed", error: e)
        end
        event
      end

      def reset!
        @adapter = nil
      end

      private

      def log(event)
        fields = { job: event.job_class, id: event.job_id, queue: event.queue, attempt: event.attempt,
                   ms: event.duration_ms, run_at: event.run_at&.utc&.iso8601 }.compact
        fields[:error] = "#{event.error.class}: #{event.error.message}" if event.error
        level = { failed: :error, retried: :warn }.fetch(event.name, :info)
        GemStack.logger.public_send(level, "job.#{event.name}", **fields)
      end
    end
  end

  class << self
    def jobs = Jobs.adapter
  end
end

require_relative "job"
require_relative "jobs/executor"
require_relative "jobs/adapters/inline"
require_relative "jobs/adapters/test"
require_relative "jobs/adapters/async"
require_relative "jobs/adapters/database"
require_relative "jobs/adapters/sidekiq"

GemStack::Config.namespace(:jobs, GemStack::Jobs::Config)
