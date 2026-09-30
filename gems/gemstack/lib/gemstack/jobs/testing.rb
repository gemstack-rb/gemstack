# frozen_string_literal: true

require "gemstack/jobs"

module GemStack
  module Jobs
    # Test helpers (included into GemStack::TestCase by the generated test helper):
    #
    #   def test_signup_sends_welcome_email
    #     post_json "/api/signups", { email: "a@b.c" }
    #
    #     assert_enqueued SendWelcomeEmail, args: [User.last.id]
    #     perform_enqueued_jobs
    #     assert_equal 1, Mailer.deliveries.size
    #   end
    module Testing
      def self.included(base)
        base.class_eval do
          def before_setup
            super
            GemStack::Jobs.adapter = GemStack::Jobs::Adapters::Test.new
          end
        end
      end

      def enqueued_jobs = Jobs.adapter.enqueued

      # Jobs of job_class (optionally with these args / on this queue) were enqueued.
      def assert_enqueued(job_class, args: nil, queue: nil, count: nil)
        matching = enqueued_jobs.select do |job|
          job["job_class"] == job_class.name && (args.nil? || job["args"] == Arguments.dump(args)) &&
            (queue.nil? || job["queue"] == queue.to_s)
        end
        message = "Expected #{job_class.name}#{" with #{args.inspect}" if args} to be enqueued; " \
                  "enqueued: #{enqueued_jobs.map { |j| [j["job_class"], j["args"]] }.inspect}"
        count ? assert_equal(count, matching.size, message) : assert(!matching.empty?, message)
      end

      def refute_enqueued(job_class)
        assert(enqueued_jobs.none? { |job| job["job_class"] == job_class.name },
               "Expected no #{job_class.name} to be enqueued")
      end

      # Runs enqueued jobs (and any they enqueue). With a block: only jobs
      # enqueued inside it. Errors raised by jobs propagate.
      def perform_enqueued_jobs(only: nil)
        return Jobs.adapter.perform_enqueued(only: only) unless block_given?

        before = enqueued_jobs.map { |job| job["id"] }
        yield
        Jobs.adapter.perform_enqueued(only: only, except_ids: before)
      end
    end
  end
end
