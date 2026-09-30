# frozen_string_literal: true

module GemStack
  module Jobs
    module Adapters
      # Runs GemStack jobs on Sidekiq (for teams already running Redis +
      # Sidekiq). Add `gem "sidekiq"`, set `config.jobs.adapter = :sidekiq`,
      # and run `bundle exec sidekiq -r ./config/sidekiq.rb` (see docs/background-jobs.md).
      #
      # GemStack's executor still decides retries and discards, so job
      # classes behave identically on every adapter; Sidekiq's own retries
      # are off and exhausted jobs go to Sidekiq's Dead set.
      class Sidekiq
        include AfterCommit

        def initialize
          require "sidekiq"
          Runner.define!
        rescue LoadError
          raise ConfigurationError, 'the :sidekiq job adapter needs `gem "sidekiq"` in the Gemfile'
        end

        def enqueue(payload)
          jid = SecureRandom.hex(12)
          after_commit { Runner.push(payload.merge("attempts" => 0), jid: jid) }
          jid
        end

        # The Sidekiq job class that executes GemStack payloads.
        module Runner
          module_function

          def define!
            return if defined?(GemStack::Jobs::SidekiqRunner)

            klass = Class.new do
              include ::Sidekiq::Job

              sidekiq_options retry: 0 # exhausted jobs → Dead set; GemStack schedules retries itself

              def perform(payload)
                payload = payload.merge("id" => jid)
                outcome = Executor.execute(payload)
                case outcome.status
                when :retry then Runner.push(payload.merge("attempts" => outcome.attempt), at: outcome.run_at)
                when :failed then raise outcome.error
                end
              end
            end
            GemStack::Jobs.const_set(:SidekiqRunner, klass)
          end

          def push(payload, at: nil, jid: nil)
            item = { "class" => GemStack::Jobs::SidekiqRunner, "queue" => payload["queue"],
                     "args" => [payload.except("run_at", "id")] }
            item["jid"] = jid if jid
            run_at = at || payload["run_at"]
            item["at"] = run_at.to_f if run_at
            ::Sidekiq::Client.push(item)
          end
        end
      end
    end
  end
end
