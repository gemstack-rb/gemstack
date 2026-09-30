# frozen_string_literal: true

require "test_helper"

# Runs against a real Redis (GEMSTACK_TEST_REDIS_URL): pushes through the
# adapter, then executes what Sidekiq would pop.
class SidekiqAdapterTest < Minitest::Test
  URL = ENV.fetch("GEMSTACK_TEST_REDIS_URL", nil)

  def setup
    skip "set GEMSTACK_TEST_REDIS_URL to run Sidekiq adapter tests" unless URL
    require "sidekiq"
    require "sidekiq/api"
    Sidekiq.configure_client { |config| config.redis = { url: URL } }
    Sidekiq.redis(&:flushdb)
    GemStack::Jobs.adapter = @adapter = GemStack::Jobs::Adapters::Sidekiq.new
    drain_record
  end

  def teardown = GemStack::Jobs.reset!

  # Pops the next job from a queue and runs it like a Sidekiq processor would.
  def run_next(queue)
    job = Sidekiq::Queue.new(queue).first or return nil
    job.delete
    runner = GemStack::Jobs::SidekiqRunner.new
    runner.jid = job.jid
    runner.perform(*job.args)
  end

  def test_push_and_perform
    jid = RecordingJob.perform_later("via sidekiq")

    assert_equal 1, Sidekiq::Queue.new("recording").size
    assert_equal jid, Sidekiq::Queue.new("recording").first.jid
    run_next("recording")

    assert_equal [[:performed, ["via sidekiq"], 1]], drain_record
  end

  def test_scheduled_jobs_go_to_the_schedule
    RecordingJob.set(wait: 600).perform_later

    assert_equal 1, Sidekiq::ScheduledSet.new.size
  end

  def test_gemstack_retry_policy_reschedules_through_sidekiq
    FlakyJob.perform_later("s")
    run_next("default")
    retry_job = Sidekiq::ScheduledSet.new.first || Sidekiq::Queue.new("default").first

    assert retry_job, "the retry is pushed back to Sidekiq"
    assert_equal 1, retry_job.args.first["attempts"]
  end

  def test_exhausted_jobs_raise_for_the_dead_set
    AlwaysFailingJob.perform_later
    payload = Sidekiq::Queue.new("default").first.args.first.merge("attempts" => 1)

    assert_raises(ArgumentError) { GemStack::Jobs::SidekiqRunner.new.perform(payload) }
  end
end
