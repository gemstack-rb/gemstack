# frozen_string_literal: true

require "test_helper"

class DatabaseQueueTest < Minitest::Test
  include JobsDB

  def store = @store ||= GemStack::Jobs::Adapters::Database.new(db: JobsDB.db)
  def rows = JobsDB.db[:gemstack_jobs]

  def enqueue(klass, *, **options)
    GemStack::Jobs.adapter = store
    options.empty? ? klass.perform_later(*) : klass.set(**options).perform_later(*)
  ensure
    GemStack::Jobs.reset!
  end

  def test_enqueue_inserts_a_row
    id = enqueue(RecordingJob, 1, { "k" => [true, nil] })
    row = rows.first(id: id)

    assert_equal ["RecordingJob", "recording", 100, 0], row.values_at(:job_class, :queue, :priority, :attempts)
    args = row[:args].is_a?(String) ? JSON.parse(row[:args]) : row[:args].to_a # jsonb on PostgreSQL, JSON text elsewhere
    assert_equal [1, { "k" => [true, nil] }], args
  end

  def test_claim_order_priority_then_run_at
    low = enqueue(RecordingJob, "low", priority: 200)
    high = enqueue(RecordingJob, "high", priority: 1)
    normal = enqueue(RecordingJob, "normal")

    assert_equal [high, normal, low], Array.new(3) { store.claim(["*"], "w")["id"] }
    assert_nil store.claim(["*"], "w")
  end

  def test_claimed_args_are_plain_ruby_values
    enqueue(RecordingJob, { "nested" => { "a" => [1] } })
    payload = store.claim(["*"], "w")

    assert_instance_of Hash, payload["args"].first
    assert_instance_of Array, payload["args"].first["nested"]["a"]
  end

  def test_future_jobs_and_queue_filtering
    enqueue(RecordingJob, "later", wait: 3600)
    enqueue(FlakyJob, "default queue")

    assert_nil store.claim(["recording"], "w")
    assert_equal "FlakyJob", store.claim(["default"], "w")["job_class"]
  end

  def test_skip_locked_gives_concurrent_workers_different_jobs
    ids = Array.new(20) { |i| enqueue(RecordingJob, i) }
    claimed = Queue.new
    threads = Array.new(4) do |t|
      Thread.new { while (job = store.claim(["*"], "w#{t}")) do claimed << job["id"] end }
    end
    threads.each(&:join)
    all = Array.new(claimed.size) { claimed.pop }

    assert_equal ids.sort, all.sort # every job claimed exactly once
  end

  def test_enqueue_is_transactional
    JobsDB.db.transaction(rollback: :always) { enqueue(RecordingJob, "rolled back") }

    assert_equal 0, rows.count
    JobsDB.db.transaction { enqueue(RecordingJob, "committed") }

    assert_equal 1, rows.count
  end

  def test_reschedule_fail_release_and_retry_failed
    id = enqueue(RecordingJob)
    store.claim(["*"], "w")
    store.reschedule(id, run_at: Time.now + 60, attempts: 1, error: RuntimeError.new("x"))
    row = rows.first(id: id)

    assert_nil row[:locked_at]
    assert_equal 1, row[:attempts]
    assert_match(/RuntimeError: x/, row[:last_error])

    store.fail(id, attempts: 2, error: RuntimeError.new("y"))

    assert rows.first(id: id)[:failed_at]
    assert_equal 1, store.stats.dig("recording", :failed)
    assert_equal([id], store.failed.map { |f| f[:id] })
    assert_equal 1, store.retry_failed

    assert_nil rows.first(id: id)[:failed_at]
    assert_equal 0, rows.first(id: id)[:attempts]
  end

  def test_stale_locks_are_released
    id = enqueue(RecordingJob)
    store.claim(["*"], "dead-worker")
    rows.where(id: id).update(locked_at: Time.now - 7200)

    assert_equal 1, store.release_stale(3600)
    assert_equal id, store.claim(["*"], "w")["id"]
  end

  def test_stats
    enqueue(RecordingJob)
    enqueue(RecordingJob, wait: 3600)
    store.claim(["*"], "w")
    enqueue(RecordingJob)

    assert_equal({ ready: 1, scheduled: 1, running: 1, failed: 0 }, store.stats["recording"])
  end
end

class WorkerTest < Minitest::Test
  include JobsDB

  def store = @store ||= GemStack::Jobs::Adapters::Database.new(db: JobsDB.db)

  def worker(**)
    # PostgreSQL: NOTIFY wakes the worker, so a slow poll proves it; elsewhere polling is the mechanism.
    poll = JobsDB.db.database_type == :postgres ? 5 : 0.2
    @worker = GemStack::Jobs::Worker.new(store: store, queues: ["*"], concurrency: 2, poll_interval: poll,
                                         lock_timeout: 60, shutdown_timeout: 1, **)
  end

  def teardown
    @worker&.shutdown if @worker&.running?
    GemStack::Jobs.reset!
  end

  def enqueue(klass, *)
    GemStack::Jobs.adapter = store
    klass.perform_later(*)
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now > deadline
    yield
  end

  def test_polling_picks_up_jobs_without_notify
    skip "PostgreSQL wakes workers with NOTIFY (next test)" if JobsDB.db.database_type == :postgres
    w = GemStack::Jobs::Worker.new(store: store, queues: ["*"], concurrency: 2)
    w.start
    sleep 0.2
    started = Time.now
    enqueue(RecordingJob, "polled")

    assert_equal [:performed, ["polled"], 1], Timeout.timeout(4) { RECORD.pop }
    assert_operator Time.now - started, :<, 2.5, "the 1 s poll picks it up"
  ensure
    w&.stop
  end

  def test_notify_wakes_idle_workers_immediately
    skip "NOTIFY is PostgreSQL-only; other databases poll" unless JobsDB.db.database_type == :postgres
    worker.start
    sleep 0.3 # workers are idle, waiting up to poll_interval (5s)
    started = Time.now
    enqueue(RecordingJob, "hello")
    item = Timeout.timeout(3) { RECORD.pop }

    assert_equal [:performed, ["hello"], 1], item
    assert_operator Time.now - started, :<, 1.5, "NOTIFY should beat the 5s poll"
    assert(wait_for { JobsDB.db[:gemstack_jobs].none? })
  end

  def test_work_once_settles_every_outcome
    w = worker
    enqueue(FlakyJob, "x")

    assert_equal :retry, w.work_once.status
    assert_equal 1, JobsDB.db[:gemstack_jobs].first[:attempts]
    assert_equal :performed, w.work_once.status # wait: 0 → ready again immediately
    assert_equal 0, JobsDB.db[:gemstack_jobs].count

    enqueue(AlwaysFailingJob)
    2.times { w.work_once }

    assert JobsDB.db[:gemstack_jobs].first[:failed_at]

    JobsDB.db[:gemstack_jobs].delete
    enqueue(DiscardingJob)

    assert_equal :discarded, w.work_once.status
    assert_equal 0, JobsDB.db[:gemstack_jobs].count
    assert_nil w.work_once
  end

  def test_shutdown_releases_unfinished_jobs
    blocker = Class.new(GemStack::Job) { def perform = sleep(10) }
    Object.const_set(:BlockingJob, blocker)
    worker.start
    enqueue(BlockingJob)

    assert(wait_for { JobsDB.db[:gemstack_jobs].exclude(locked_at: nil).any? })
    @worker.shutdown

    row = JobsDB.db[:gemstack_jobs].first

    assert_nil row[:locked_at], "an unfinished job goes back to the queue"
  ensure
    Object.send(:remove_const, :BlockingJob) if defined?(BlockingJob)
  end
end
