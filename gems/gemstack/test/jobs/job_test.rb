# frozen_string_literal: true

require "test_helper"

class JobDSLTest < Minitest::Test
  include GemStack::Jobs::Testing

  class BaseJob < GemStack::Job
    queue :mailers
    priority 5
  end

  class ChildJob < BaseJob
    def perform(user_id, options = {}) = RECORD << [user_id, options]
  end

  def setup = drain_record

  def test_queue_and_priority_inheritance
    assert_equal "mailers", ChildJob.queue
    assert_equal 5, ChildJob.priority
    assert_equal "default", RecordingJob.superclass.queue
    assert_equal 100, GemStack::Job.priority
  end

  def test_perform_later_records_a_json_payload
    id = ChildJob.perform_later(42, { locale: :fr, "tags" => [:a] })

    assert_equal 1, id
    payload = enqueued_jobs.first

    assert_equal "JobDSLTest::ChildJob", payload["job_class"]
    assert_equal [42, { "locale" => "fr", "tags" => ["a"] }], payload["args"]
    assert_equal "mailers", payload["queue"]
    assert_nil payload["run_at"]
    assert_enqueued ChildJob, args: [42, { "locale" => "fr", "tags" => ["a"] }]
  end

  def test_set_overrides
    ChildJob.set(queue: :urgent, priority: 1).perform_later(1)
    ChildJob.set(wait: 60).perform_later(2)
    at = Time.now + 3600
    ChildJob.set(at: at).perform_later(3)
    first, second, third = enqueued_jobs

    assert_equal ["urgent", 1], first.values_at("queue", "priority")
    assert_in_delta Time.now + 60, second["run_at"], 2
    assert_equal at, third["run_at"]
  end

  def test_arguments_must_be_json
    record = Struct.new(:id).new(1)

    error = assert_raises(GemStack::Jobs::SerializationError) { ChildJob.perform_later(record) }
    assert_includes error.message, "pass its id instead"
    assert_raises(GemStack::Jobs::SerializationError) { ChildJob.perform_later(Float::NAN) }
    assert_raises(GemStack::Jobs::SerializationError) { ChildJob.perform_later({ 1 => "x" }) }
    assert_raises(GemStack::Jobs::SerializationError) { ChildJob.perform_later(Time.now) }
    assert_empty enqueued_jobs
  end

  def test_perform_now_uses_the_json_form
    ChildJob.perform_now(7, { key: :value })

    assert_equal [[7, { "key" => "value" }]], drain_record
  end

  def test_anonymous_jobs_cannot_be_enqueued
    assert_raises(ArgumentError) { Class.new(GemStack::Job).perform_later }
  end

  def test_retry_decisions
    max, wait = FlakyJob.retry_decision(RuntimeError.new, 1)

    assert_equal [3, 0.0], [max, wait]
    assert_nil FlakyJob.retry_decision(RuntimeError.new, 3).last
    max, wait = RecordingJob.retry_decision(StandardError.new, 1)

    assert_equal 10, max
    assert_operator wait, :>=, 16 # 1**4 + 15
    assert_operator RecordingJob.retry_decision(StandardError.new, 5).last, :>, 600
  end

  def test_refute_enqueued_and_count
    RecordingJob.perform_later
    RecordingJob.perform_later

    assert_enqueued RecordingJob, count: 2
    refute_enqueued ChildJob
  end
end

class ExecutorTest < Minitest::Test
  E = GemStack::Jobs::Executor

  def setup
    drain_record
    @events = []
    @subscriber = GemStack::Jobs.subscribe { |event| @events << event.name }
  end

  def teardown = GemStack::Jobs.unsubscribe(@subscriber)

  def payload(klass, args = [], attempts: 0) = { "job_class" => klass.name, "args" => args, "attempts" => attempts, "id" => 9 }

  def test_performed
    outcome = E.execute(payload(RecordingJob, [1]))

    assert_equal [:performed, 1], [outcome.status, outcome.attempt]
    assert_equal [[:performed, [1], 1]], drain_record
    assert_equal [:performed], @events
  end

  def test_retry_then_fail
    outcome = E.execute(payload(AlwaysFailingJob))

    assert_equal :retry, outcome.status
    assert_kind_of Time, outcome.run_at
    outcome = E.execute(payload(AlwaysFailingJob, attempts: 1))

    assert_equal [:failed, 2], [outcome.status, outcome.attempt]
    assert_equal %i[retried failed], @events
  end

  def test_discard
    assert_equal :discarded, E.execute(payload(DiscardingJob)).status
    assert_equal [:discarded], @events
  end

  def test_unknown_and_non_job_classes_never_run
    assert_equal :failed, E.execute({ "job_class" => "NoSuchJob", "args" => [] }).status
    assert_equal :failed, E.execute({ "job_class" => "Kernel", "args" => [] }).status
    assert_equal :failed, E.execute({ "job_class" => "String", "args" => [] }).status
  end

  def test_a_broken_subscriber_does_not_break_jobs
    broken = GemStack::Jobs.subscribe(:performed) { raise "boom" }

    assert_equal :performed, E.execute(payload(RecordingJob)).status
  ensure
    GemStack::Jobs.unsubscribe(broken)
  end
end

class TestAdapterTest < Minitest::Test
  include GemStack::Jobs::Testing

  def setup = drain_record

  def test_perform_enqueued_runs_chains
    EnqueuingJob.perform_later(3)
    perform_enqueued_jobs

    assert_equal [[:done]], drain_record
    assert_empty enqueued_jobs
  end

  def test_errors_surface_in_tests
    AlwaysFailingJob.perform_later

    assert_raises(ArgumentError) { perform_enqueued_jobs }
  end

  def test_block_form_only_runs_jobs_enqueued_inside
    RecordingJob.perform_later("before")
    perform_enqueued_jobs { RecordingJob.perform_later("inside") }

    assert_equal [[:performed, ["inside"], 1]], drain_record
    assert_equal([["before"]], enqueued_jobs.map { |job| job["args"] })
  end
end

class InlineAndAsyncAdapterTest < Minitest::Test
  def setup = drain_record

  def teardown
    @async&.shutdown
    GemStack::Jobs.reset!
  end

  def test_inline_runs_immediately_and_raises
    GemStack::Jobs.adapter = GemStack::Jobs::Adapters::Inline.new
    RecordingJob.perform_later("now")

    assert_equal [[:performed, ["now"], 1]], drain_record
    assert_raises(ArgumentError) { AlwaysFailingJob.perform_later }
  end

  def test_async_runs_schedules_and_retries
    GemStack::Jobs.adapter = @async = GemStack::Jobs::Adapters::Async.new(concurrency: 2)
    FlakyJob.perform_later("k")
    RecordingJob.set(wait: 0.2).perform_later("later")
    RecordingJob.perform_later("soon")
    @async.drain(timeout: 5)
    records = drain_record

    assert_includes records, [:recovered, "k", 2]
    assert_equal([[:performed, ["soon"], 1], [:performed, ["later"], 1]], records.select { |r| r[0] == :performed })
  end

  def test_unknown_adapter
    assert_raises(GemStack::ConfigurationError) { GemStack::Jobs.build_adapter(:beanstalk) }
  end

  def test_default_adapter_is_test_in_tests
    assert_equal :test, GemStack::Jobs::Config.new.adapter
  end
end
