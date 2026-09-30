# frozen_string_literal: true

require "test_helper"

class ApplicationTest < Minitest::Test
  include AppFixture
  include GemStack::Testing::Helpers

  CONTROLLER = <<~RUBY
    class WidgetsController < GemStack::Controller
      def index = render([{ id: 1, name: Widgets::Namer.name_for(1) }])
    end
  RUBY

  SERVICE = <<~RUBY
    module Widgets
      class Namer
        def self.name_for(id) = "widget-\#{id}"
      end
    end
  RUBY

  ROUTES = <<~RUBY
    GemStack.routes do
      resources :widgets, only: :index
    end
  RUBY

  def standard_app(**)
    build_app({ "app/controllers/widgets_controller.rb" => CONTROLLER,
                "app/services/widgets/namer.rb" => SERVICE,
                "config/routes.rb" => ROUTES }, **)
  end

  def test_boots_autoloads_every_app_directory_and_routes
    standard_app
    get_json "/api/widgets"

    assert_status 200
    assert_equal [{ "id" => 1, "name" => "widget-1" }], json_body
    assert_equal(["GET /api/widgets"], GemStack.routes.map { |r| "#{r.verb} #{r.path}" })
  end

  def test_boot_is_idempotent
    app = standard_app
    app.boot!
    router = app.router
    app.boot!

    assert_same router, app.router
  end

  def test_api_path_is_configurable
    standard_app
    GemStack.config.http.api_path = "/v1"
    get_json "/v1/widgets"

    assert_status 200
    get_json "/api/widgets"

    assert_status 404
  end

  def test_loads_env_files_without_overriding_env
    build_app({ ".env" => "GEMSTACK_FIXTURE_A=file\nGEMSTACK_FIXTURE_B=file\n" })
    ENV["GEMSTACK_FIXTURE_B"] = "real"
    GemStack.boot!

    assert_equal "file", ENV.fetch("GEMSTACK_FIXTURE_A")
    assert_equal "real", ENV.fetch("GEMSTACK_FIXTURE_B")
  ensure
    ENV.delete("GEMSTACK_FIXTURE_A")
    ENV.delete("GEMSTACK_FIXTURE_B")
  end

  def test_loads_environment_config
    build_app({ "config/environments/test.rb" => "GemStack.config.http.max_body_size = 42\n" })
    GemStack.boot!

    assert_equal 42, GemStack.config.http.max_body_size
  end

  def test_plugins_run_during_boot
    seen = nil
    GemStack::Plugins.register(:fixture) { |app| seen = app }
    app = build_app
    app.boot!

    assert_same app, seen
  ensure
    GemStack::Plugins.unregister(:fixture)
  end

  def test_reload_picks_up_code_and_route_changes
    app = standard_app
    app.config.reload_code = true
    app.boot!
    write("app/services/widgets/namer.rb", SERVICE.sub("widget-", "gadget-"))
    write("config/routes.rb", ROUTES.sub("only: :index", "only: %i[index show]"))
    app.reload!
    get_json "/api/widgets"

    assert_equal "gadget-1", json_body.first["name"]
    assert_equal 2, app.routes.size
  end

  def test_development_reloader_middleware
    app = standard_app(env: "development")
    app.boot!

    assert app.config.http.middleware.include?(GemStack::Reloader)
    get_json "/api/widgets"

    assert_equal "widget-1", json_body.first["name"]
    write("app/services/widgets/namer.rb", SERVICE.sub("widget-", "fresh-"))
    get_json "/api/widgets"

    assert_equal "fresh-1", json_body.first["name"]
  end

  def test_reload_requires_reloading_enabled
    app = standard_app
    app.boot!

    error = assert_raises(GemStack::ConfigurationError) { app.reload! }
    assert_includes error.message, "reload_code"
  end

  def test_no_reloader_outside_development
    app = standard_app
    app.boot!

    refute app.config.http.middleware.include?(GemStack::Reloader)
  end

  def test_eager_load_in_production
    app = standard_app(env: "production")
    app.boot!

    assert Object.const_defined?(:WidgetsController, false)
  end

  def test_missing_routes_file_means_no_routes
    build_app
    get_json "/api/anything"

    assert_error 404, "route_not_found"
    get_json "/api/health"

    assert_status 200
  end

  def test_shutdown_hooks_run_in_reverse
    app = build_app
    calls = []
    app.on_shutdown { calls << 1 }
    app.on_shutdown { calls << 2 }
    app.shutdown

    assert_equal [2, 1], calls
  end
end

class InterlockTest < Minitest::Test
  def test_exclusive_waits_for_readers
    lock = GemStack::Interlock.new
    events = Queue.new
    lock.acquire_shared
    writer = Thread.new { lock.exclusive { events << :write } }
    sleep 0.05
    events << :read_done
    lock.release_shared
    writer.join(2)

    assert_equal %i[read_done write], [events.pop, events.pop]
  end

  def test_readers_wait_for_writer
    lock = GemStack::Interlock.new
    order = Queue.new
    release = Queue.new
    writer = Thread.new do
      lock.exclusive do
        order << :writing
        release.pop
      end
    end
    sleep 0.05 until order.size == 1
    reader = Thread.new do
      lock.acquire_shared
      order << :reading
      lock.release_shared
    end
    sleep 0.05

    assert_equal 1, order.size
    release << true
    [writer, reader].each { |t| t.join(2) }

    assert_equal %i[writing reading], [order.pop, order.pop]
  end
end

class JITConfigTest < Minitest::Test
  def config(env = "production", var = nil)
    GemStack.env = env
    ENV["GEMSTACK_JIT"] = var if var
    GemStack::Config.new.jit
  ensure
    ENV.delete("GEMSTACK_JIT")
    GemStack.env = "test"
  end

  def test_defaults_and_override
    assert_equal :yjit, config("production")
    assert_nil config("development")
    assert_equal :zjit, config("production", "zjit")
    assert_nil config("production", "off")
  end

  def test_unknown_jit_is_a_configuration_error
    app = GemStack::Application.new(config: GemStack::Config.new.tap { |c| c.jit = :turbo })

    assert_raises(GemStack::ConfigurationError) { app.send(:enable_jit) }
  end
end
