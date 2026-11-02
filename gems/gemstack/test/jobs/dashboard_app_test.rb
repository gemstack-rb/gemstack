# frozen_string_literal: true

require "test_helper"
require "sequel"
require "gemstack/db"

class DashboardAppTest < Minitest::Test
  class FakeDashboard
    attr_reader :calls

    def initialize
      @calls = []
      @job = { id: 7, queue: "<img src=x onerror=alert(1)>", priority: 1, job_class: "Danger<Job>",
               args: [{ "value" => "<script>alert(1)</script>" }], run_at: Time.now, attempts: 4,
               last_error: "DangerError: <script>bad error</script>\n/path/to/job.rb:4:in perform", locked_at: nil, locked_by: nil,
               failed_at: Time.now, created_at: Time.now }
    end

    def stats
      @calls << :stats
      { "<queue>" => { ready: 2, scheduled: 1, running: 0, failed: 1, completed: 3 } }
    end

    def list(state: nil, queue: nil, page: 1, per_page: 25)
      @calls << [:list, state, queue, page, per_page]
      { items: [{ id: 7, queue: @job[:queue], job_class: @job[:job_class], attempts: 4,
                  args: @job[:args], last_error: @job[:last_error], created_at: @job[:created_at],
                  run_at: @job[:run_at], failed_at: @job[:failed_at], state: "failed" }],
        page: Integer(page), per_page: per_page, total: 100 }
    end

    def find(id)
      @calls << [:find, id]
      @job if id.to_i == @job[:id]
    end

    def retry_failed(id)
      @calls << [:retry, id]
      id.to_i == 7
    end

    def discard_failed(id)
      @calls << [:discard, id]
      id.to_i == 7
    end

    def run_now(id)
      @calls << [:run_now, id]
      id.to_i == 8
    end

    def delete_pending(id)
      @calls << [:delete_pending, id]
      id.to_i == 8
    end

    def retry_failed_jobs(ids)
      @calls << [:retry_many, ids]
      ids.size
    end

    def run_now_jobs(ids)
      @calls << [:run_now_many, ids]
      ids.size
    end

    def delete_jobs(ids)
      @calls << [:delete_many, ids]
      ids.size
    end
  end

  def setup
    @config = GemStack.config.jobs.dashboard
    @config.enabled = true
    @config.path = "/jobs"
    @config.authorization = nil
    @dashboard = FakeDashboard.new
    @app = GemStack::Jobs::DashboardApp.new(config: @config, dashboard: @dashboard)
  end

  def call(path, method: "GET", input: nil, cookie: nil, content_type: nil)
    env = Rack::MockRequest.env_for(path, method: method, input: input,
                                          "HTTP_COOKIE" => cookie,
                                          "CONTENT_TYPE" => content_type)
    @app.call(env)
  end

  def test_overview_and_filtered_paginated_list
    status, headers, body = call("/jobs")
    html = body.join

    assert_equal 200, status
    assert_equal "no-store", headers["cache-control"]
    assert_match(%r{Path=/jobs; HttpOnly; SameSite=Strict}, headers["set-cookie"])
    assert_includes html, "Overview"
    assert_includes html, "Recent jobs"
    assert_includes html, "GemStack Jobs"
    assert_includes html, "Ready</span><strong>2"
    assert_includes html, "Completed</span><strong>3"
    assert_includes html, "&lt;queue&gt;"
    refute_includes html, "<queue>"

    status, _, body = call("/jobs/failed?queue=mailers&page=2")

    assert_equal 200, status
    assert_includes @dashboard.calls, [:list, "failed", "mailers", "2", 25]
    html = body.join
    assert_includes html, "state-tabs"
    assert_includes html, "name=\"queue\""
    assert_includes html, "name=\"ids[]\""
    assert_includes html, "DangerError"
    refute_match(/<label>State\s*<select/, html)
    assert_includes html, "Showing 26–50 of 100"
    assert_includes html, "queue=mailers&amp;page=1"
    assert_includes html, "Previous"
    assert_includes html, "Next"
    refute_includes html, "state=failed"
  end

  def test_tab_paths_are_routes_and_legacy_list_urls_redirect
    status, _, body = call("/jobs/ready")
    assert_equal 200, status
    assert_includes body.join, "Ready"
    assert_includes @dashboard.calls, [:list, "ready", nil, "1", 25]
    refute_includes @dashboard.calls, [:find, "ready"]

    status, headers, = call("/jobs/jobs?state=failed&queue=default&page=2")
    assert_equal 301, status
    assert_equal "/jobs/failed?queue=default&page=2", headers["location"]

    status, headers, = call("/jobs/jobs")
    assert_equal 301, status
    assert_equal "/jobs/all", headers["location"]
  end

  def test_completed_is_a_dashboard_tab
    status, _, body = call("/jobs/completed?queue=mailers&page=2")

    assert_equal 200, status
    assert_includes body.join, "Completed"
    assert_includes @dashboard.calls, [:list, "completed", "mailers", "2", 25]
  end

  def test_legacy_detail_url_redirects_to_numeric_detail_route
    status, headers, = call("/jobs/jobs/7?queue=default&page=2")
    assert_equal 301, status
    assert_equal "/jobs/7?queue=default&page=2", headers["location"]
  end

  def test_job_detail_escapes_untrusted_data_and_provides_mutation_forms
    status, headers, body = call("/jobs/7")
    html = body.join

    assert_equal 200, status
    assert_includes html, "Danger&lt;Job&gt;"
    assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert_includes html, "&lt;script&gt;bad error&lt;/script&gt;"
    assert_includes html, "DangerError"
    assert_includes html, "/path/to/job.rb:4:in perform"
    assert_includes html, "Retry"
    assert_includes html, "Delete"
    assert_includes html, "name=\"_csrf\""
    assert_includes headers["content-security-policy"], "frame-ancestors 'none'"
  end

  def test_retry_and_discard_require_a_valid_csrf_token
    _, headers, page = call("/jobs/7")
    cookie = headers.fetch("set-cookie").split(";", 2).first
    token = page.join[/name="_csrf" value="([a-f0-9]+)"/, 1]
    form = URI.encode_www_form("_csrf" => token)

    status, response_headers, = call("/jobs/7/retry", method: "POST", input: form,
                                                      cookie: cookie, content_type: "application/x-www-form-urlencoded")

    assert_equal 303, status
    assert_equal "/jobs/7?notice=retried", response_headers["location"]
    assert_includes @dashboard.calls, [:retry, "7"]

    status, = call("/jobs/7/delete?failed=1", method: "POST", input: "_csrf=invalid",
                                              cookie: cookie, content_type: "application/x-www-form-urlencoded")

    assert_equal 403, status
    refute_includes @dashboard.calls, [:discard, "7"]
  end

  def test_pending_actions_and_bulk_actions_require_csrf_and_preserve_list_filters
    _, headers, page = call("/jobs/scheduled?queue=mailers&page=2")
    cookie = headers.fetch("set-cookie").split(";", 2).first
    token = page.join[/name="_csrf" value="([a-f0-9]+)"/, 1]
    bulk_form = URI.encode_www_form("_csrf" => token, "ids[]" => %w[8 9], "return_to" => "scheduled",
                                    "queue" => "mailers", "page" => "2")

    status, = call("/jobs/8/run_now", method: "POST",
                                      input: URI.encode_www_form("_csrf" => token), cookie: cookie,
                                      content_type: "application/x-www-form-urlencoded")
    assert_equal 303, status
    assert_includes @dashboard.calls, [:run_now, "8"]

    status, response_headers, = call("/jobs/bulk/run_now", method: "POST", input: bulk_form, cookie: cookie,
                                                           content_type: "application/x-www-form-urlencoded")
    assert_equal 303, status
    assert_equal "/jobs/scheduled?queue=mailers&page=2&notice=bulk-run-now-2", response_headers["location"]
    assert_includes @dashboard.calls, [:run_now_many, %w[8 9]]

    status, = call("/jobs/8/delete", method: "POST", input: "_csrf=invalid", cookie: cookie,
                                     content_type: "application/x-www-form-urlencoded")
    assert_equal 403, status
    refute_includes @dashboard.calls, [:delete_pending, "8"]
  end

  def test_authorization_disabled_mount_and_not_found_paths
    @config.authorization = ->(_env) { false }
    status, = call("/jobs")

    assert_equal 404, status
    refute_includes @dashboard.calls, :stats

    @config.authorization = nil
    @config.enabled = false
    status, = call("/jobs")
    assert_equal 404, status
    @config.enabled = true
    status, = call("/jobs-extra")
    assert_equal 404, status
  end

  def test_database_failures_show_a_safe_migration_hint
    broken = Object.new
    def broken.stats = raise(Sequel::DatabaseConnectionError, "database unavailable")
    @app = GemStack::Jobs::DashboardApp.new(config: @config, dashboard: broken)

    status, _, body = call("/jobs")

    assert_equal 503, status
    assert_includes body.join, "Check the database and jobs migration"
    refute_includes body.join, "raw database secret"
  end

  def test_missing_jobs_table_is_a_service_unavailable_response
    broken = Object.new
    def broken.stats = raise(Sequel::DatabaseError, "SQLite3::SQLException: no such table: gemstack_jobs")
    @app = GemStack::Jobs::DashboardApp.new(config: @config, dashboard: broken)

    status, _, body = call("/jobs")

    assert_equal 503, status
    assert_includes body.join, "Check the database and jobs migration"
  end

  def test_unexpected_errors_show_the_exception_and_backtrace_in_development
    original_env = GemStack.env
    GemStack.env = "development"
    broken = Object.new
    def broken.stats = raise(NoMethodError, "synthetic retry failure")
    @app = GemStack::Jobs::DashboardApp.new(config: @config, dashboard: broken)

    status, _, body = call("/jobs")

    assert_equal 500, status
    assert_includes body.join, "NoMethodError"
    assert_includes body.join, "synthetic retry failure"
    assert_includes body.join, "dashboard_app_test.rb"
  ensure
    GemStack.env = original_env
  end
end

class DashboardAppDatabaseActionsTest < Minitest::Test
  def setup
    Sequel.database_timezone = :utc
    @db = Sequel.sqlite
    GemStack::Jobs::Migration.apply(@db)
    @adapter = GemStack::Jobs::Adapters::Database.new(db: @db)
    @dashboard = GemStack::Jobs::Dashboard.new(adapter: @adapter)
    @config = GemStack.config.jobs.dashboard
    @config.enabled = true
    @config.path = "/jobs"
    @config.authorization = nil
    @app = GemStack::Jobs::DashboardApp.new(config: @config, dashboard: @dashboard)
  end

  def teardown
    @db&.disconnect
  end

  def make_job(state: :failed, attempts: 1, last_error: nil, run_at: Time.now - 60)
    now = Time.now
    attrs = { queue: "default", priority: 100, job_class: "DashboardFailure", args: "[]",
              run_at: run_at, attempts: attempts, last_error: last_error, created_at: now }
    attrs[:failed_at] = now if state == :failed
    attrs[:completed_at] = now if state == :completed
    @db[:gemstack_jobs].insert(attrs)
  end

  def test_completed_job_is_kept_listed_and_can_be_deleted
    completed = make_job(state: :completed)
    jobs = GemStack::Jobs::Adapters::Database.new(db: @db)
    listing = jobs.list_jobs(state: :completed)

    assert_equal([completed], listing[:items].map { |job| job[:id] })
    assert_equal "completed", listing[:items].first[:state]

    cookie, token, html = page("/jobs/completed")
    assert_includes html, "Delete"
    status, = post("/jobs/#{completed}/delete", cookie, token)

    assert_equal 303, status
    assert_nil @db[:gemstack_jobs].first(id: completed)
  end

  def page(path)
    status, headers, body = @app.call(Rack::MockRequest.env_for(path))
    raise "dashboard page returned #{status}" unless status == 200

    cookie = headers.fetch("set-cookie").split(";", 2).first
    token = body.join[/name="_csrf" value="([a-f0-9]+)"/, 1]
    [cookie, token, body.join]
  end

  def post(path, cookie, token, params = {})
    pairs = [["_csrf", token]] + params.flat_map do |key, value|
      value.is_a?(Array) ? value.map { |item| [key, item] } : [[key, value]]
    end
    input = URI.encode_www_form(pairs)
    @app.call(Rack::MockRequest.env_for(path, method: "POST", input: input,
                                              "HTTP_COOKIE" => cookie,
                                              "CONTENT_TYPE" => "application/x-www-form-urlencoded"))
  end

  def test_retry_clears_empty_error_fields_and_restores_ready_state
    id = make_job(last_error: nil)
    cookie, token, html = page("/jobs/failed")
    assert_includes html, "No error details recorded"
    refute_match(%r{<strong></strong>:\s*</td>}, html)

    status, headers, = post("/jobs/#{id}/retry?return_to=failed&page=1", cookie, token)

    assert_equal 303, status
    assert_match(%r{\A/jobs/failed\?page=1&notice=retried\z}, headers["location"])
    row = @db[:gemstack_jobs].first(id: id)
    assert_nil row[:failed_at]
    assert_nil row[:last_error]
    assert_equal 0, row[:attempts]
    assert_operator Time.parse(row[:run_at].to_s), :>=, Time.now - 2
  end

  def test_empty_tab_shows_friendly_pagination_footer
    _, _, html = page("/jobs/failed")
    assert_includes html, "No jobs to show"
    refute_includes html, "Showing 0–0 of 0"
  end

  def test_retry_clears_a_normal_error_and_backtrace
    id = make_job(last_error: "RuntimeError: broken\n/path/to/job.rb:9:in perform")
    cookie, token, html = page("/jobs/failed")
    assert_includes html, "RuntimeError: broken"

    status, = post("/jobs/#{id}/retry", cookie, token)

    assert_equal 303, status
    row = @db[:gemstack_jobs].first(id: id)
    assert_nil row[:failed_at]
    assert_nil row[:last_error]
    assert_equal 0, row[:attempts]
  end

  def test_retry_selected_retries_only_the_selected_failed_jobs
    first = make_job(last_error: "RuntimeError: first")
    second = make_job(last_error: "RuntimeError: second")
    untouched = make_job(last_error: "RuntimeError: third")
    cookie, token, = page("/jobs/failed")

    status, headers, = post("/jobs/bulk/retry", cookie, token,
                            "ids[]" => [first.to_s, second.to_s],
                            "return_to" => "failed", "page" => "1")

    assert_equal 303, status
    assert_includes headers["location"], "notice=bulk-retry-2"
    [first, second].each do |id|
      row = @db[:gemstack_jobs].first(id: id)
      assert_nil row[:failed_at]
      assert_nil row[:last_error]
      assert_equal 0, row[:attempts]
    end
    assert @db[:gemstack_jobs].first(id: untouched)[:failed_at]
  end

  def test_retrying_a_missing_job_returns_a_conflict_page_not_a_server_error
    make_job(last_error: "RuntimeError: retained for CSRF page")
    cookie, token, = page("/jobs/failed")

    status, _, body = post("/jobs/99999/retry", cookie, token)

    assert_equal 409, status
    assert_includes body.join, "This job has changed state"
    refute_includes body.join, "temporarily unavailable"
  end

  def test_delete_run_now_and_bulk_delete_apply_only_to_unlocked_jobs
    failed = make_job(last_error: "RuntimeError: discard me")
    ready = make_job(state: :ready)
    scheduled = make_job(state: :scheduled, run_at: Time.now + 3600)
    scheduled2 = make_job(state: :scheduled, run_at: Time.now + 3600)
    running = make_job(state: :running)
    ready2 = make_job(state: :ready)
    now = Time.now
    @db[:gemstack_jobs].where(id: running).update(locked_at: now, locked_by: "worker")
    cookie, token, = page("/jobs/scheduled")

    status, = post("/jobs/#{scheduled}/run_now", cookie, token)
    assert_equal 303, status
    assert_operator @db[:gemstack_jobs].first(id: scheduled)[:run_at], :<=, Time.now

    status, = post("/jobs/bulk/run_now", cookie, token,
                   "ids[]" => [scheduled2.to_s, running.to_s])
    assert_equal 303, status
    assert_operator @db[:gemstack_jobs].first(id: scheduled2)[:run_at], :<=, Time.now
    assert @db[:gemstack_jobs].first(id: running)[:locked_at]

    status, = post("/jobs/#{failed}/delete?failed=1", cookie, token)
    assert_equal 303, status
    assert_nil @db[:gemstack_jobs].first(id: failed)

    status, = post("/jobs/#{ready}/delete", cookie, token)
    assert_equal 303, status
    assert_nil @db[:gemstack_jobs].first(id: ready)

    status, = post("/jobs/bulk/delete", cookie, token,
                   "ids[]" => [ready2.to_s, running.to_s])
    assert_equal 303, status
    assert_nil @db[:gemstack_jobs].first(id: ready2)
    assert @db[:gemstack_jobs].first(id: running), "a running job cannot be deleted"
  end
end
