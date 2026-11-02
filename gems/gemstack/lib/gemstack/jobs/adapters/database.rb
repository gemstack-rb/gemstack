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
        # database has it); completed and failed jobs stay available for history.
        Sequel.migration do
          up do
            partial = database_type != :mysql # MySQL has no partial indexes
            ready = partial ? { where: Sequel.lit("failed_at IS NULL AND completed_at IS NULL AND locked_at IS NULL") } : {}
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
              column :completed_at, :timestamptz
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

      COMPLETED_AT_SOURCE = <<~RUBY
        # frozen_string_literal: true

        # Keep successful jobs in the queue table for dashboard history.
        Sequel.migration do
          change do
            alter_table(:gemstack_jobs) do
              add_column :completed_at, :timestamptz
            end
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
        DASHBOARD_STATES = %w[ready scheduled running failed completed].freeze
        MAX_DASHBOARD_PAGE_SIZE = 100

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
            ready = dataset.where(failed_at: nil, completed_at: nil, locked_at: nil).where { run_at <= now }
            ready = ready.where(queue: queues) unless queues.include?("*")
            ready = ready.order(:priority, :run_at, :id).limit(1)
            ready = ready.for_update.skip_locked if ready.supports_skip_locked?
            row = ready.select(*returned_columns).first
            dataset.where(id: row[:id]).update(locked_at: now, locked_by: worker) if row
            row && payload_for(row)
          end
        end

        def complete(id)
          dataset.where(id: id).update(completed_at: Time.now, locked_at: nil, locked_by: nil, last_error: nil)
        end

        def discard(id) = dataset.where(id: id).delete

        def reschedule(id, run_at:, attempts:, error:)
          dataset.where(id: id).update(locked_at: nil, locked_by: nil, run_at: run_at, attempts: attempts,
                                       last_error: describe(error))
        end

        def fail(id, attempts:, error:)
          return dataset.where(id: id).delete unless Jobs.config.keep_failed

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

        # Single-record variants used by operational interfaces. The failed
        # predicate is part of the mutation query to prevent stale UI actions
        # from changing a job that has already left the failed state.
        def retry_failed_job(id)
          id = positive_integer(id, "id")
          dataset.where(id: id).exclude(failed_at: nil)
                 .update(failed_at: nil, attempts: 0, run_at: Time.now, last_error: nil) == 1
        end

        def discard_failed_job(id)
          id = positive_integer(id, "id")
          dataset.where(id: id).exclude(failed_at: nil).delete == 1
        end

        def failed(limit: 20)
          dataset.exclude(failed_at: nil).order(Sequel.desc(:failed_at)).limit(limit)
                 .select(:id, :queue, :job_class, :attempts, :failed_at, :last_error).all
        end

        # A bounded, dashboard-facing list of persisted jobs. Arguments are
        # included for the UI, but error traces remain detail-only.
        #
        # Returns { items:, page:, per_page:, total: }.
        # rubocop:disable-next Metrics/AbcSize
        def list_jobs(state: nil, queue: nil, page: 1, per_page: 25)
          page = positive_integer(page, "page")
          per_page = positive_integer(per_page, "per_page")
          if per_page > MAX_DASHBOARD_PAGE_SIZE
            raise ArgumentError, "per_page must be at most #{MAX_DASHBOARD_PAGE_SIZE}"
          end

          state = state&.to_s
          if state && !DASHBOARD_STATES.include?(state)
            raise ArgumentError, "state must be one of #{DASHBOARD_STATES.join(", ")}"
          end

          now = Time.now
          jobs = dataset
          jobs = jobs.where(queue: queue.to_s) unless queue.nil? || queue.to_s.empty?
          jobs = filter_state(jobs, state, now) if state
          total = jobs.count
          items = jobs.order(*dashboard_order).limit(per_page).offset((page - 1) * per_page)
                      .select(:id, :queue, :priority, :job_class, :args, :run_at, :attempts,
                              :last_error, :locked_at, :locked_by, :failed_at, :completed_at, :created_at).all
          items = items.map do |row|
            row = row.to_hash
            row[:args] = decode_args(row[:args])
            row.merge(state: job_state(row, now))
          end
          { items: items, page: page, per_page: per_page, total: total }
        end

        # Dashboard actions operate only on unlocked rows. They never alter a
        # running job or the worker's claim/execute lifecycle.
        def run_job_now(id)
          id = positive_integer(id, "id")
          eligible = dataset.where(id: id, failed_at: nil, completed_at: nil, locked_at: nil)
          row = eligible.select(:queue).first
          return false unless row

          changed = eligible.update(run_at: Time.now) == 1
          db.notify(CHANNEL, payload: row[:queue]) if changed && postgres?
          changed
        end

        def delete_pending_job(id)
          id = positive_integer(id, "id")
          dataset.where(id: id, failed_at: nil, locked_at: nil).delete == 1
        end

        def run_jobs_now(ids)
          ids = dashboard_ids(ids)
          return 0 if ids.empty?

          eligible = dataset.where(id: ids, failed_at: nil, completed_at: nil, locked_at: nil)
          queues = eligible.select_map(:queue).uniq if postgres?
          changed = eligible.update(run_at: Time.now)
          queues.each { |queue| db.notify(CHANNEL, payload: queue) } if changed.positive? && postgres?
          changed
        end

        def delete_jobs(ids)
          ids = dashboard_ids(ids)
          return 0 if ids.empty?

          dataset.where(id: ids, locked_at: nil).delete
        end

        def retry_failed_jobs(ids) = retry_failed(dashboard_ids(ids))

        # Full details for one persisted job, including decoded JSON args and
        # its error. Returns nil when no matching row exists.
        def find_job(id)
          id = positive_integer(id, "id")
          row = dataset.where(id: id).select(*detail_columns).first
          return unless row

          result = row.to_hash
          result[:args] = decode_args(result.delete(:args_json))
          result
        end

        # { "default" => { ready:, scheduled:, running:, failed:, completed: }, ... }
        def stats
          now = Time.now
          states = Sequel.case(
            [[Sequel.~(completed_at: nil), "completed"], [Sequel.~(failed_at: nil), "failed"],
             [Sequel.~(locked_at: nil), "running"],
             [Sequel[:run_at] > now, "scheduled"]], "ready"
          )
          dataset.group_and_count(:queue, states.as(:state)).all.each_with_object({}) do |row, result|
            state_counts = result[row[:queue]] ||= {
              ready: 0, scheduled: 0, running: 0, failed: 0, completed: 0
            }
            state_counts[row[:state].to_sym] = row[:count]
          end
        end

        private

        def positive_integer(value, name)
          number = case value
                   when Integer then value
                   when String then Integer(value, 10)
                   else raise ArgumentError
                   end
          raise ArgumentError, "#{name} must be positive" unless number.positive?

          number
        rescue TypeError, ArgumentError
          raise ArgumentError, "#{name} must be a positive integer"
        end

        def dashboard_ids(values)
          values = Array(values)
          raise ArgumentError, "at most 100 jobs may be selected" if values.size > 100

          values.map { |value| positive_integer(value, "id") }.uniq
        end

        def filter_state(jobs, state, now)
          case state
          when "ready" then jobs.where(failed_at: nil, completed_at: nil, locked_at: nil).where { run_at <= now }
          when "scheduled" then jobs.where(failed_at: nil, completed_at: nil, locked_at: nil).where { run_at > now }
          when "running" then jobs.where(Sequel.&(Sequel[:failed_at] =~ nil, Sequel.~(locked_at: nil)))
          when "failed" then jobs.where(Sequel.~(failed_at: nil))
          when "completed" then jobs.where(Sequel.~(completed_at: nil))
          end
        end

        def job_state(row, now)
          return "failed" if row[:failed_at]
          return "completed" if row[:completed_at]
          return "running" if row[:locked_at]
          return "scheduled" if row[:run_at] > now

          "ready"
        end

        def dashboard_order
          [Sequel.desc(:created_at), Sequel.desc(:id)]
        end

        def detail_columns
          [:id, :queue, :priority, :job_class,
           postgres? ? Sequel.cast(:args, :text).as(:args_json) : Sequel.as(:args, :args_json),
           :run_at, :attempts, :last_error, :locked_at, :locked_by, :failed_at, :completed_at, :created_at]
        end

        def decode_args(value)
          return value if value.is_a?(Hash) || value.is_a?(Array)

          JSON.parse(value.to_s)
        end

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
