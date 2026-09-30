# frozen_string_literal: true

module GemStack
  module Dev
    # Runs `gemstack dev`: the gateway on the public port, the Ruby API and
    # Next.js on private ports chosen automatically, prefixed output, restarts
    # of the API when configuration changes, and a clean shutdown on Ctrl-C.
    class Supervisor
      LOOPBACK = "127.0.0.1"
      TICK = 0.25

      attr_reader :gateway, :processes

      def initialize(root:, config: GemStack.config, terminal: Terminal.new, env: ENV)
        @root = Pathname.new(root)
        @config = config
        @dev = config.dev
        @terminal = terminal
        @env = env
        @processes = {}
        @stopping = false
      end

      def run
        if frontend?
          check_node!
          prepare_frontend
        end
        start
        install_signal_handlers
        loop_until_stopped
      ensure
        shutdown
      end

      def start
        @started_at = monotonic
        api_port = Ports.free(LOOPBACK)
        web_port = Ports.free(LOOPBACK) if frontend?
        @gateway = Gateway.new(
          port: @dev.port, bind: @dev.bind, api_path: @config.http.api_path,
          api: Gateway::Upstream.new(:api, LOOPBACK, api_port, "Ruby API"),
          frontend: web_port && Gateway::Upstream.new(:next, LOOPBACK, web_port, "Next.js"),
          on_error: ->(e) { @terminal.line("gateway", "#{e.class}: #{e.message}") }
        ).start

        start_processes(api_port, web_port)
        @restart_watcher = FileWatcher.new(@dev.restart_on, root: @root, exclude: @dev.restart_exclude)
        @recovery_watcher = FileWatcher.new(["app/**/*", "config/**/*", "Gemfile.lock"], root: @root)
        @jobs_watcher = FileWatcher.new(["app/**/*.rb", "db/migrations/*.rb"], root: @root) if @dev.jobs_command
        start_jobs if jobs_enabled?
        if web_port && @dev.contract_command
          @contract_watcher = FileWatcher.new(@dev.contract_watch, root: @root)
          @contract_pending = true # generate once at startup
        end
        banner
        watch_readiness
        self
      end

      def start_processes(api_port, web_port)
        @processes[:api] = spawn("api", @dev.api_command, @root, api_env(api_port))
        @processes[:next] = spawn("next", frontend_command(web_port), frontend_dir, frontend_env(api_port)) if web_port
      end

      def spawn(name, command, dir, env)
        ManagedProcess.new(name, command, terminal: @terminal, chdir: dir, env: env).start
      end

      def stop!
        @stopping = true
      end

      def shutdown
        return if @shut_down

        @shut_down = true
        @terminal.puts
        @terminal.line("gemstack", "shutting down…")
        @processes.values.map { |process| Thread.new { process.stop } }.each(&:join)
        @gateway&.stop
      end

      private

      def frontend? = frontend_dir.join("package.json").file?
      def frontend_dir = @root.join(@dev.frontend_dir)

      def api_env(port)
        {
          "GEMSTACK_ENV" => @env.fetch("GEMSTACK_ENV", "development"),
          "GEMSTACK_API_HOST" => LOOPBACK,
          "GEMSTACK_API_PORT" => port.to_s,
          "GEMSTACK_LOG_COLOR" => @terminal.color ? "1" : "0",
          "PORT" => nil # the public port belongs to the gateway
        }
      end

      def frontend_env(api_port)
        {
          "GEMSTACK_API_URL" => "http://#{LOOPBACK}:#{api_port}",
          "NEXT_PUBLIC_GEMSTACK_API_PATH" => @config.http.api_path,
          "FORCE_COLOR" => @terminal.color ? "1" : nil,
          "PORT" => nil
        }
      end

      def frontend_command(port)
        return Array(@dev.frontend_command) + ["--port", port.to_s] if @dev.frontend_command

        [frontend_dir.join("node_modules/.bin/next").to_s, "dev", "--hostname", LOOPBACK, "--port", port.to_s]
      end

      # Next.js exits at once on an old Node.js with a line that's easy to miss
      # among the other output; say it up front, with the command that fixes it.
      def check_node!(node = Toolchain.node)
        return if node && Toolchain.node_ok?(node[:version])

        wanted = [@root.join(".node-version"), @root.join(".nvmrc")].find(&:file?)&.read&.strip
        wanted = Toolchain::LTS_NODE if wanted.nil? || wanted.empty?
        found = node ? "Node.js #{node[:version]} (#{node[:path]})" : "no `node` on the PATH"
        raise Error, "Next.js needs Node.js #{Toolchain::MIN_NODE.join(".")} or newer; found #{found}.\n  " \
                     "→ #{Toolchain.node_hint(wanted, Toolchain.node_manager(node&.fetch(:path)))}"
      end

      # Installs frontend dependencies on first run so `gemstack new && gemstack dev`
      # works even with --skip-install.
      def prepare_frontend
        return if frontend_dir.join("node_modules/.bin/next").exist?

        manager = package_manager
        @terminal.line("gemstack", "installing frontend dependencies with #{manager} (first run)…")
        installer = ManagedProcess.new(manager, [manager, "install"], terminal: @terminal, chdir: frontend_dir).start
        sleep 0.1 while installer.running?
        return if installer.status.is_a?(Process::Status) && installer.status.success?

        raise Error, "#{manager} install failed (#{installer.describe_status}) in #{frontend_dir}"
      end

      def package_manager
        {
          "pnpm-lock.yaml" => "pnpm", "yarn.lock" => "yarn", "bun.lockb" => "bun", "bun.lock" => "bun"
        }.each { |lock, manager| return manager if frontend_dir.join(lock).exist? }
        "npm"
      end

      def banner
        url = "http://localhost:#{@gateway.port}"
        t = @terminal
        t.puts
        t.puts("  #{t.bold("GemStack")} #{t.dim("v#{GemStack::VERSION} · #{@env.fetch("GEMSTACK_ENV",
                                                                                      "development")}")}")
        t.puts
        split = t.dim("(#{@config.http.api_path}/* → Ruby, everything else → Next.js)")
        t.puts("  #{t.green("✓")} Gateway    #{url}  #{split}")
        t.puts("  #{t.yellow("…")} Ruby API   #{t.dim("starting on #{@gateway.api} (internal)")}")
        if @gateway.frontend
          t.puts("  #{t.yellow("…")} Next.js    #{t.dim("starting on #{@gateway.frontend} (internal)")}")
        else
          t.puts("  #{t.dim("-")} Next.js    #{t.dim("no #{@dev.frontend_dir}/package.json — API only")}")
        end
        t.puts
        t.puts("  Application: #{t.bold(url)}")
        t.puts
      end

      def watch_readiness
        [@gateway.api, @gateway.frontend].compact.each do |upstream|
          Thread.new do
            until @stopping
              if Ports.open?(upstream.host, upstream.port)
                seconds = (monotonic - @started_at).round(1)
                @terminal.line("gemstack", "#{@terminal.green("✓")} #{upstream.label} ready (#{seconds}s)")
                break
              end
              sleep TICK
            end
          end
        end
      end

      def install_signal_handlers
        %w[INT TERM].each { |signal| trap(signal) { @stopping = true } }
      end

      def loop_until_stopped
        until @stopping
          sleep TICK
          supervise
        end
      end

      def supervise
        api = @processes[:api]
        if @restart_watcher.changed?
          restart_api("configuration changed")
        elsif !api.running? && api.exited?
          report_exit(api)
          restart_api("files changed") if @recovery_watcher.changed?
        end
        web = @processes[:next]
        report_exit(web) if web && !web.running? && web.exited?
        supervise_contract
        supervise_jobs
      end

      # A worker only makes sense with the database queue and its table.
      def jobs_enabled?
        return false unless @dev.jobs_command && defined?(GemStack::Jobs) && @config.respond_to?(:jobs)
        return false unless %w[database postgres].include?(@config.jobs.adapter.to_s)

        Dir.glob(@root.join("db/migrations/*_create_gemstack_jobs.rb").to_s).any?
      end

      def start_jobs
        @processes[:jobs] = spawn("jobs", @dev.jobs_command, @root, { "GEMSTACK_ENV" => "development" })
      end

      # The worker doesn't reload code, so restart it when app/ changes
      # (it finishes running jobs first), and start it once the jobs table exists.
      def supervise_jobs
        return unless @jobs_watcher&.changed?

        jobs = @processes[:jobs]
        if jobs&.running?
          @terminal.line("gemstack", "app changed — restarting job worker")
          jobs.restart
        elsif jobs_enabled?
          start_jobs
        end
      end

      # One contract run at a time; changes during a run queue exactly one more.
      def supervise_contract
        return unless @contract_watcher

        @contract_pending = true if @contract_watcher.changed?
        running = @processes[:contract]&.running?
        return if running || !@contract_pending

        @contract_pending = false
        @processes[:contract] = spawn("contract", @dev.contract_command, @root, { "GEMSTACK_ENV" => "development" })
      end

      # Both watchers overlap (config/), so re-baseline both after a restart
      # to avoid restarting twice for a single change.
      def restart_api(reason)
        @terminal.line("gemstack", "#{reason} — restarting Ruby API")
        @processes[:api].restart
        @restart_watcher.changed?
        @recovery_watcher.changed?
        @reported_exit = nil
      end

      def report_exit(process)
        key = [process.name, process.pid]
        return if @reported_exit&.include?(key)

        (@reported_exit ||= []) << key
        hint = process.name == "api" ? " — fix the error; it restarts when you save a file" : ""
        @terminal.line("gemstack", @terminal.red("#{process.name} exited (#{process.describe_status})#{hint}"))
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
