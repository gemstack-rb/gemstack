# frozen_string_literal: true

module GemStack
  module Jobs
    # The migration new apps get (and `gemstack jobs:install` writes). Kept
    # as source text so the app owns a plain, readable migration while tests
    # and the generator share one definition.
    module Migration
      SOURCE = <<~RUBY
        # frozen_string_literal: true

        # The GemStack job queue (docs/background-jobs.md), for PostgreSQL, MySQL and
        # SQLite. Workers claim rows one at a time (FOR UPDATE SKIP LOCKED where the
        # database has it); finished jobs are deleted, exhausted ones keep failed_at.
        Sequel.migration do
          up do
            partial = database_type != :mysql # MySQL has no partial indexes
            ready = partial ? { where: Sequel.lit("failed_at IS NULL AND locked_at IS NULL") } : {}
            create_table(:gemstack_jobs) do
              primary_key :id, type: :Bignum
              String :queue, null: false, default: "default"
              Integer :priority, null: false, default: 100
              String :job_class, null: false
              column :args, :jsonb, null: false # json on MySQL and SQLite
              column :run_at, :timestamptz, null: false
              Integer :attempts, null: false, default: 0
              String :last_error, text: true
              column :locked_at, :timestamptz
              String :locked_by
              column :failed_at, :timestamptz
              column :created_at, :timestamptz, null: false

              # The fetch query: ready jobs by queue, in priority/run_at order.
              index %i[queue priority run_at id], name: :gemstack_jobs_ready, **ready
              index :locked_at, name: :gemstack_jobs_locked
              index :failed_at, name: :gemstack_jobs_failed
            end
          end

          down do
            drop_table(:gemstack_jobs)
          end
        end
      RUBY

      def self.apply(db, direction = :up)
        Sequel.extension :migration
        eval(SOURCE, TOPLEVEL_BINDING, "gemstack_jobs_migration.rb").apply(db, direction) # rubocop:disable Security/Eval
      end
    end

    module Adapters
      # The default adapter: jobs are rows in the application's database
      # — PostgreSQL, MySQL or SQLite.
      #
      # - Enqueueing is an INSERT on the current connection, so inside
      #   GemStack.transaction a job exists only if the transaction commits.
      # - Workers claim one job at a time in a short transaction: with
      #   FOR UPDATE SKIP LOCKED on PostgreSQL and MySQL 8, so workers never
      #   block each other; on SQLite by taking the write lock up front.
      # - PostgreSQL also NOTIFYs idle workers at once; elsewhere (and as a
      #   safety net) workers poll every config.jobs.poll_interval.
      # - Times are set from Ruby, in UTC, so the database clock and time zone
      #   never matter.
      class Database
        CHANNEL = "gemstack_jobs"

        def initialize(db: nil, table: Jobs.config.table)
          @db = db
          @table = table
        end

        def db
          @db || begin
            require "gemstack/db"
            GemStack::DB.connection
          end
        end

        def dataset = db[@table]
        def postgres? = db.database_type == :postgres

        def enqueue(payload)
          now = Time.now
          args = postgres? ? Sequel.pg_jsonb_wrap(payload["args"]) : JSON.generate(payload["args"])
          id = dataset.insert(job_class: payload["job_class"], queue: payload["queue"], priority: payload["priority"],
                              args: args, run_at: payload["run_at"] || now, created_at: now)
          db.notify(CHANNEL, payload: payload["queue"]) if postgres?
          id
        end

        # Claims the next ready job for these queues ("*" = all). Returns a
        # payload Hash or nil.
        def claim(queues, worker)
          now = Time.now
          db.transaction(**claim_options) do
            ready = dataset.where(failed_at: nil, locked_at: nil).where { run_at <= now }
            ready = ready.where(queue: queues) unless queues.include?("*")
            ready = ready.order(:priority, :run_at, :id).limit(1)
            ready = ready.for_update.skip_locked if ready.supports_skip_locked?
            row = ready.select(*returned_columns).first
            dataset.where(id: row[:id]).update(locked_at: now, locked_by: worker) if row
            row && payload_for(row)
          end
        end

        def complete(id) = dataset.where(id: id).delete

        def reschedule(id, run_at:, attempts:, error:)
          dataset.where(id: id).update(locked_at: nil, locked_by: nil, run_at: run_at, attempts: attempts,
                                       last_error: describe(error))
        end

        def fail(id, attempts:, error:)
          return complete(id) unless Jobs.config.keep_failed

          dataset.where(id: id).update(locked_at: nil, locked_by: nil, failed_at: Time.now,
                                       attempts: attempts, last_error: describe(error))
        end

        # Releases this worker's claimed jobs (graceful shutdown).
        def release(worker) = dataset.where(locked_by: worker).update(locked_at: nil, locked_by: nil)

        # Releases jobs locked longer than `timeout` seconds (their worker died).
        def release_stale(timeout)
          cutoff = Time.now - Float(timeout)
          dataset.where { locked_at < cutoff }.update(locked_at: nil, locked_by: nil)
        end

        # Failed jobs back to the queue: all, or the given ids.
        def retry_failed(ids = nil)
          failed = dataset.exclude(failed_at: nil)
          failed = failed.where(id: ids) if ids
          failed.update(failed_at: nil, attempts: 0, run_at: Time.now, last_error: nil)
        end

        def discard_failed(ids = nil)
          failed = dataset.exclude(failed_at: nil)
          failed = failed.where(id: ids) if ids
          failed.delete
        end

        def failed(limit: 20)
          dataset.exclude(failed_at: nil).order(Sequel.desc(:failed_at)).limit(limit)
                 .select(:id, :queue, :job_class, :attempts, :failed_at, :last_error).all
        end

        # { "default" => { ready:, scheduled:, running:, failed: }, ... }
        def stats
          now = Time.now
          states = Sequel.case(
            [[Sequel.~(failed_at: nil), "failed"], [Sequel.~(locked_at: nil), "running"],
             [Sequel[:run_at] > now, "scheduled"]], "ready"
          )
          dataset.group_and_count(:queue, states.as(:state)).all.each_with_object({}) do |row, result|
            (result[row[:queue]] ||= { ready: 0, scheduled: 0, running: 0, failed: 0 })[row[:state].to_sym] =
              row[:count]
          end
        end

        private

        # SQLite: take the write lock when the transaction starts, so two
        # workers can't both read the same ready row.
        def claim_options = db.database_type == :sqlite ? { mode: :immediate } : {}

        # args as text, parsed with the json gem: jobs receive plain Hash/Array
        # values rather than Sequel's JSONB wrappers. (Lazy: Sequel may not be loaded.)
        def returned_columns
          @returned_columns ||= [:id, :job_class, :queue, :priority, :attempts,
                                 postgres? ? Sequel.cast(:args, :text).as(:args_json) : Sequel.as(:args, :args_json)]
        end

        def payload_for(row)
          { "id" => row[:id], "job_class" => row[:job_class], "queue" => row[:queue],
            "priority" => row[:priority], "args" => JSON.parse(row[:args_json].to_s), "attempts" => row[:attempts] }
        end

        def describe(error)
          "#{error.class}: #{error.message}\n#{Array(error.backtrace).first(20).join("\n")}"[0, 10_000]
        end
      end

      # The adapter's name before it supported MySQL and SQLite; `adapter: :postgres` still works.
      Postgres = Database
    end
  end
end
