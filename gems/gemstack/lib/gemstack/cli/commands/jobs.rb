# frozen_string_literal: true

module GemStack
  class CLI < Thor
    map "jobs:status" => :jobs_status, "jobs:retry" => :jobs_retry, "jobs:discard" => :jobs_discard,
        "jobs:install" => :jobs_install, "jobs:failed" => :jobs_failed

    desc "jobs", "Run a background job worker (PostgreSQL queue)"
    method_option :queues, aliases: "-q", type: :string, desc: "Comma-separated queues (default: all)"
    method_option :concurrency, aliases: "-c", type: :numeric,
                                desc: "Worker threads (default: GEMSTACK_JOB_CONCURRENCY or 5)"
    def jobs
      with_jobs do |config|
        config.jobs.queues = options[:queues].split(",").map(&:strip) if options[:queues]
        config.jobs.concurrency = options[:concurrency] if options[:concurrency]
        # Each worker thread holds a connection, plus LISTEN and the reaper.
        config.db.pool_size = [config.db.pool_size, config.jobs.concurrency + 2].max
        GemStack.boot!
        GemStack.application.eager_load!
        require "gemstack/jobs/worker"
        Jobs::Worker.new.run
      end
    end

    desc "jobs:status", "Show queued, scheduled, running and failed jobs per queue"
    def jobs_status
      with_jobs(quiet: true) do
        stats = Jobs::Adapters::Database.new.stats
        return say("No jobs.") if stats.empty?

        rows = stats.sort.map { |queue, s| [queue, s[:ready], s[:scheduled], s[:running], s[:failed]].map(&:to_s) }
        print_table([%w[Queue Ready Scheduled Running Failed], *rows])
      end
    end

    desc "jobs:failed", "List recently failed jobs"
    method_option :limit, type: :numeric, default: 20
    def jobs_failed
      with_jobs(quiet: true) do
        failed = Jobs::Adapters::Database.new.failed(limit: options[:limit])
        return say("No failed jobs.") if failed.empty?

        failed.each do |job|
          say("##{job[:id]} #{job[:job_class]} (#{job[:queue]}) " \
              "attempts=#{job[:attempts]} failed_at=#{job[:failed_at]}")
          say("    #{job[:last_error].to_s.lines.first&.strip}")
        end
      end
    end

    desc "jobs:retry [IDS...]", "Put failed jobs back on the queue (all failed jobs without IDS)"
    def jobs_retry(*ids)
      with_jobs(quiet: true) do
        count = Jobs::Adapters::Database.new.retry_failed(ids.empty? ? nil : ids.map(&:to_i))
        say("Re-queued #{count} job(s).")
      end
    end

    desc "jobs:discard [IDS...]", "Delete failed jobs (all failed jobs without IDS)"
    def jobs_discard(*ids)
      with_jobs(quiet: true) do
        count = Jobs::Adapters::Database.new.discard_failed(ids.empty? ? nil : ids.map(&:to_i))
        say("Deleted #{count} failed job(s).")
      end
    end

    desc "jobs:install", "Add the gemstack_jobs table migration (done automatically by `generate job`)"
    def jobs_install
      JobGenerator.install_migration(Project.root!, output: $stdout)
    end

    no_commands do
      def with_jobs(quiet: false)
        root = Project.ensure_bundle!(self.class.argv)
        ENV["GEMSTACK_ENV"] = options[:environment] || ENV["GEMSTACK_ENV"] || "development"
        Project.load_config!(root)
        unless defined?(GemStack::Jobs)
          abort('This app doesn\'t load background jobs. Add `require "gemstack/jobs"` to config/app.rb.')
        end
        config = GemStack.config
        config.reload_code = false
        if quiet
          config.logger.level = :warn
          config.db.log_queries = false if config.respond_to?(:db)
        end
        yield config
      rescue Sequel::DatabaseError => e
        raise unless e.message.include?("gemstack_jobs")

        abort("The gemstack_jobs table doesn't exist yet. Run `gemstack jobs:install && gemstack db:migrate`.")
      rescue Sequel::DatabaseConnectionError => e
        abort("Can't connect to the database: #{e.message.lines.first.strip}")
      end
    end
  end
end
