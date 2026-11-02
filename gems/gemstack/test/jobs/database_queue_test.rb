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

  def test_completed_history_migration_upgrades_an_existing_jobs_table
    db = JobsDB.db
    db.drop_table(:gemstack_jobs)
    db.create_table(:gemstack_jobs) { primary_key :id }
    Sequel.extension :migration
    eval(GemStack::Jobs::Migration::COMPLETED_AT_SOURCE, TOPLEVEL_BINDING,
         "add_completed_at_to_gemstack_jobs.rb").apply(db, :up)

    assert_includes db.schema(:gemstack_jobs).map(&:first), :completed_at
  ensure
    db&.drop_table?(:gemstack_jobs)
    GemStack::Jobs::Migration.apply(db) if db
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

    assert_equal({ ready: 1, scheduled: 1, running: 1, failed: 0, completed: 0 }, store.stats["recording"])
  end

  def test_dashboard_lists_are_filtered_bounded_and_include_derived_state
    ready = enqueue(RecordingJob, "ready")
    scheduled = enqueue(RecordingJob, "scheduled", wait: 3600)
    running = enqueue(RecordingJob, "running")
    failed = enqueue(RecordingJob, "failed")
    rows.where(id: running).update(locked_at: Time.now, locked_by: "dashboard-worker")
    rows.where(id: failed).update(locked_at: nil, locked_by: nil, failed_at: Time.now,
                                 last_error: "RuntimeError: broken")

    all = store.list_jobs(per_page: 10)
    assert_equal 4, all[:total]
    assert_equal %w[failed ready running scheduled], all[:items].map { |job| job[:state] }.sort
    ordered = store.list_jobs(per_page: 4)[:items]
    assert_equal [failed, running, scheduled, ready], ordered.map { |job| job[:id] }
    assert_equal ["failed"], ordered.first[:args]
    assert_equal ["ready"], store.list_jobs(state: :ready, queue: "recording")[:items].map { |job| job[:state] }
    assert_equal [scheduled], store.list_jobs(state: "scheduled")[:items].map { |job| job[:id] }
    assert_equal [running], store.list_jobs(state: "running")[:items].map { |job| job[:id] }
    assert_equal [failed], store.list_jobs(state: "failed")[:items].map { |job| job[:id] }
    assert_equal [failed], store.list_jobs(page: 1, per_page: 1)[:items].map { |job| job[:id] }
    assert_equal [running], store.list_jobs(page: 2, per_page: 1)[:items].map { |job| job[:id] }
    assert_raises(ArgumentError) { store.list_jobs(per_page: 101) }
    assert_raises(ArgumentError) { store.list_jobs(state: "unknown") }
    assert_raises(ArgumentError) { store.list_jobs(page: 0) }
  end

  def test_dashboard_detail_decodes_args_and_single_job_actions_only_change_failed_jobs
    failed = enqueue(RecordingJob, { "nested" => [1, true] })
    ready = enqueue(RecordingJob, "still ready")
    rows.where(id: failed).update(failed_at: Time.now, last_error: "RuntimeError: broken")

    detail = store.find_job(failed)
    assert_equal({ "nested" => [1, true] }, detail[:args].first)
    assert_equal "RuntimeError: broken", detail[:last_error]
    assert_nil store.find_job(999_999)
    assert_raises(ArgumentError) { store.find_job("not-an-id") }

    assert store.retry_failed_job(failed)
    refute store.retry_failed_job(ready)
    assert_nil rows.first(id: failed)[:failed_at]
    refute store.discard_failed_job(ready)
    rows.where(id: failed).update(failed_at: Time.now)
    assert store.discard_failed_job(failed)
    assert_nil rows.first(id: failed)
  end

  def test_dashboard_run_now_and_delete_actions_only_touch_unlocked_jobs
    ready = enqueue(RecordingJob, "ready")
    scheduled = enqueue(RecordingJob, "scheduled", wait: 3600)
    running = enqueue(RecordingJob, "running")
    failed = enqueue(RecordingJob, "failed")
    rows.where(id: running).update(locked_at: Time.now, locked_by: "worker")
    rows.where(id: failed).update(failed_at: Time.now)

    assert store.run_job_now(scheduled)
    assert_operator rows.first(id: scheduled)[:run_at], :<=, Time.now
    refute store.run_job_now(running)
    refute store.run_job_now(failed)
    assert store.delete_pending_job(ready)
    refute store.delete_pending_job(running)
    refute store.delete_pending_job(failed)
    assert rows.first(id: running)
    assert rows.first(id: failed)
  end

  def test_dashboard_bulk_actions_limit_ids_and_never_touch_running_jobs
    scheduled = enqueue(RecordingJob, "scheduled", wait: 3600)
    ready = enqueue(RecordingJob, "ready")
    running = enqueue(RecordingJob, "running")
    failed = enqueue(RecordingJob, "failed")
    rows.where(id: running).update(locked_at: Time.now, locked_by: "worker")
    rows.where(id: failed).update(failed_at: Time.now)

    assert_equal 1, store.run_jobs_now([scheduled, running, failed])
    assert_equal 1, store.retry_failed_jobs([failed, ready])
    assert_equal 1, store.delete_jobs([ready, running])
    assert rows.first(id: running)
    assert rows.first(id: failed)
    assert_raises(ArgumentError) { store.delete_jobs(Array.new(101, ready)) }
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
    assert(wait_for { JobsDB.db[:gemstack_jobs].where(completed_at: nil).none? })
  end

  def test_work_once_settles_every_outcome
    w = worker
    completed = enqueue(FlakyJob, "x")

    assert_equal :retry, w.work_once.status
    assert_equal 1, JobsDB.db[:gemstack_jobs].first[:attempts]
    assert_equal :performed, w.work_once.status # wait: 0 → ready again immediately
    assert JobsDB.db[:gemstack_jobs].first(id: completed)[:completed_at]
    assert_nil JobsDB.db[:gemstack_jobs].first(id: completed)[:last_error]
    assert_equal 1, store.list_jobs(state: :completed)[:total]
    assert_nil store.claim(["*"], "another-worker")

    enqueue(AlwaysFailingJob)
    2.times { w.work_once }

    assert JobsDB.db[:gemstack_jobs].exclude(failed_at: nil).first[:failed_at]

    JobsDB.db[:gemstack_jobs].where(completed_at: nil).delete
    enqueue(DiscardingJob)

    assert_equal :discarded, w.work_once.status
    assert_equal [completed], JobsDB.db[:gemstack_jobs].select_map(:id)
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
