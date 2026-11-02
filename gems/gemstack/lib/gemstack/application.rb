# frozen_string_literal: true

require "zeitwerk"

module GemStack
  # A GemStack application: configuration + autoloaded code + routes, served
  # as a Rack app. There is one per process, available as GemStack.application.
  #
  # Boot sequence (idempotent):
  #   1. load .env files                             config.env_files
  #   2. load config/environments/<env>.rb if present
  #   3. run plugin hooks                             GemStack::Plugins
  #   4. set up Zeitwerk for every directory in app/  (+ config.autoload_paths)
  #   5. load config/routes.rb
  #   6. compile the middleware stack                 config.http.middleware
  #   7. eager load in production                     config.eager_load
  class Application
    attr_reader :config, :loader, :router

    def initialize(config: GemStack.config)
      @config = config
      @booted = false
      @boot_lock = Mutex.new
      @shutdown_hooks = []
      @reload_hooks = []
    end

    def root = Pathname.new(config.root)

    def boot!
      @boot_lock.synchronize do
        return self if @booted

        load_env_files
        load_environment_config
        enable_jit
        Plugins.run(self)
        setup_loader
        @router = build_router { load_routes }
        install_reloader if config.reload_code
        @http = HTTP::App.new(config: config.http, router: @router)
        @rack_app = build_rack_app
        eager_load! if config.eager_load
        @booted = true
      end
      self
    end

    def booted? = @booted

    def call(env)
      boot! unless @booted
      @rack_app.call(env)
    end

    # Replaces the route table. Called by config/routes.rb via GemStack.routes.
    def draw_routes(&)
      raise ArgumentError, "GemStack.routes needs a block" unless block_given?

      @pending_routes << Proc.new(&) if @pending_routes # collected while (re)loading routes.rb
    end

    def routes = @router&.routes || []

    # Unloads and reloads app/ code and routes. Used by the development
    # Reloader; safe to call from the console.
    def reload!
      unless config.reload_code
        raise ConfigurationError, "code reloading is disabled; set config.reload_code = true (default in development)"
      end

      @loader&.reload
      @router = build_router { load_routes }
      @http.router = @router
      @reload_hooks.each(&:call)
      GemStack.logger.debug("reloaded application code")
      true
    end

    def eager_load!
      @loader&.eager_load
    end

    # Runs after code and routes reload (development), e.g. to re-read config/channels.rb.
    def on_reload(&block)
      @reload_hooks << block
    end

    def on_shutdown(&block)
      @shutdown_hooks << block
    end

    def shutdown
      @shutdown_hooks.reverse_each(&:call)
    end

    def autoload_dirs
      app_dirs = Dir.glob(root.join("app/*").to_s)
      extra = Array(config.autoload_paths).map { |path| File.expand_path(path, root) }
      (app_dirs + extra).select { |path| File.directory?(path) }
    end

    # Held shared while application code runs (requests, realtime handlers),
    # exclusively while code reloads.
    def interlock = @interlock ||= Interlock.new

    private

    def load_env_files = GemStack.load_env_files!

    # Enables config.jit unless a JIT is already running (e.g. `ruby --yjit`).
    def enable_jit
      jit = config.jit
      return unless jit

      engine = { yjit: :YJIT, zjit: :ZJIT }.fetch(jit.to_sym) do
        raise ConfigurationError, "unknown config.jit #{jit.inspect} (use :yjit, :zjit or nil)"
      end
      return unless RubyVM.const_defined?(engine)
      return if %i[YJIT ZJIT].any? { |name| RubyVM.const_defined?(name) && RubyVM.const_get(name).enabled? }

      RubyVM.const_get(engine).enable
    end

    def load_environment_config
      file = root.join("config/environments/#{GemStack.env}.rb")
      load file.to_s if file.file?
    end

    def setup_loader
      @loader = Zeitwerk::Loader.new
      @loader.tag = "gemstack.app"
      autoload_dirs.each { |dir| @loader.push_dir(dir) }
      @loader.enable_reloading if config.reload_code
      @loader.setup
    end

    # Inside the ErrorHandler, so errors raised while reloading (e.g. a
    # SyntaxError) are rendered as JSON error responses.
    def install_reloader
      stack = config.http.middleware
      return if stack.include?(Reloader)

      if stack.include?(HTTP::Middleware::ErrorHandler)
        stack.insert_after(HTTP::Middleware::ErrorHandler, Reloader, self)
      else
        stack.unshift(Reloader, self)
      end
    end

    def load_routes
      file = root.join("config/routes.rb")
      load file.to_s if file.file?
    end

    def build_router
      @pending_routes = []
      yield
      router = HTTP::Router.new(prefix: config.http.api_path)
      @pending_routes.each { |block| router.draw(&block) }
      router
    ensure
      @pending_routes = nil
    end

    def build_rack_app
      return @http unless defined?(GemStack::Jobs)

      dashboard = config.jobs.dashboard
      return @http unless dashboard.enabled

      validate_dashboard_mount!(dashboard.path)
      endpoint = Jobs::DashboardApp.new(config: dashboard)
      HTTP::PathDispatch.new(@http, path: dashboard.path, mounted_app: endpoint)
    end

    def validate_dashboard_mount!(path)
      api_path = normalize_mount_path(config.http.api_path)
      dashboard_path = normalize_mount_path(path)
      health_path = config.http.health_path && normalize_mount_path(config.http.health_path)

      if paths_overlap?(api_path, dashboard_path)
        raise ConfigurationError,
              "jobs dashboard path #{dashboard_path.inspect} overlaps config.http.api_path #{api_path.inspect}"
      end
      return unless health_path && paths_overlap?(health_path, dashboard_path)

      raise ConfigurationError,
            "jobs dashboard path #{dashboard_path.inspect} overlaps config.http.health_path #{health_path.inspect}"
    end

    def normalize_mount_path(path)
      value = path.to_s.gsub(%r{/+}, "/").sub(%r{/$}, "")
      if value.empty?
        "/"
      else
        (value.start_with?("/") ? value : "/#{value}")
      end
    end

    def paths_overlap?(left, right)
      left == "/" || right == "/" || left == right || left.start_with?("#{right}/") || right.start_with?("#{left}/")
    end
  end
end
