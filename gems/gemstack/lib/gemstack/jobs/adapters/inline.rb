# frozen_string_literal: true

module GemStack
  module Jobs
    module Adapters
      # Runs jobs immediately, in the caller's thread, ignoring schedules and
      # retries. Errors propagate, so nothing is silently swallowed. Handy for
      # scripts and debugging.
      class Inline
        def enqueue(payload)
          id = SecureRandom.uuid
          job = Executor.resolve(payload["job_class"]).new
          job.job_id = id
          job.attempt = 1
          job.perform(*Arguments.load(payload["args"]))
          id
        end
      end

      # Defers a block until the surrounding database transaction commits
      # (when gemstack/db is loaded), so a job never runs before — or without —
      # the data it depends on. The :postgres adapter gets this for free by
      # inserting into the same transaction.
      module AfterCommit
        def after_commit(&)
          db = defined?(GemStack::DB) && GemStack::DB.connected? ? GemStack::DB.connection : nil
          return yield unless db&.in_transaction?

          db.after_commit(&)
        end
      end
    end
  end
end
