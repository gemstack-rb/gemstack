# frozen_string_literal: true

require "test_helper"
require "gemstack/jobs"

class JobsDashboardMountTest < Minitest::Test
  include AppFixture
  include GemStack::Testing::Helpers

  ROUTES = <<~RUBY
    GemStack.routes do
      get "/ping", to: ->(_env) { [200, { "content-type" => "text/plain" }, ["pong"]] }
    end
  RUBY

  def build_dashboard_app
    app = build_app({ "config/routes.rb" => ROUTES })
    app.config.jobs.adapter = :async
    app
  end

  def test_dashboard_mount_is_outside_api_and_non_database_adapter_does_not_break_boot
    app = build_dashboard_app
    app.config.http.api_path = "/v1"

    get "/jobs"
    assert_status 503
    assert_includes last_response.body, "database job adapter"
    assert_equal "no-store", last_response.headers["cache-control"]

    get "/v1/ping"
    assert_status 200
    assert_equal "pong", last_response.body
    get "/api/ping"
    assert_status 404
  end

  def test_configured_mount_path_and_disabled_dashboard
    app = build_dashboard_app
    app.config.jobs.dashboard.path = "/ops/jobs"

    get "/ops/jobs"
    assert_status 503
    get "/jobs"
    assert_status 404
  end

  def test_disabled_dashboard_leaves_api_dispatch_unchanged
    app = build_dashboard_app
    app.config.jobs.dashboard.enabled = false
    get "/jobs"
    assert_status 404
    assert_equal "application/json; charset=utf-8", last_response.headers["content-type"]
  end

  def test_dashboard_mount_conflicts_fail_at_boot
    app = build_dashboard_app
    app.config.http.api_path = "/jobs"

    error = assert_raises(GemStack::ConfigurationError) { app.boot! }
    assert_includes error.message, "overlaps config.http.api_path"
  end

  def test_health_check_conflict_fails_at_boot
    app = build_dashboard_app
    app.config.http.health_path = "/jobs/health"

    error = assert_raises(GemStack::ConfigurationError) { app.boot! }
    assert_includes error.message, "overlaps config.http.health_path"
  end
end
