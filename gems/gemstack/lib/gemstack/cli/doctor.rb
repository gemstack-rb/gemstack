# frozen_string_literal: true

require "open3"
require "socket"
require "gemstack/dev"
require_relative "doctor/upgrade_check"
require_relative "doctor/secret_checks"

module GemStack
  class CLI < Thor
    # `gemstack doctor` — checks that an application can run, and says how to
    # fix what can't. Every check is independent: one
    # failure never hides the others. `--production` checks the settings a
    # deploy needs.
    class Doctor
      include UpgradeCheck
      include SecretChecks

      Result = Struct.new(:status, :title, :hint)

      attr_reader :results

      def initialize(root:, output: $stdout, production: false, color: output.tty?, run: nil)
        @root = root
        @output = output
        @production = production
        @color = color
        @run = run || ->(*command) { Open3.capture2e(*command) }
        @results = []
      end

      def run
        header
        check_ruby
        check_node
        check_frontend_dependencies
        check_git_secrets
        check_kamal_secrets
        check_gemstack_upgrade
        booted = check_boot
        if booted
          database_ok = check_database
          check_migrations_and_jobs if database_ok
          check_cache
          check_realtime_broker
          check_contract if database_ok
        end
        check_production_settings if @production
        check_port unless @production
        summary
        self
      end

      def ok? = results.none? { |result| result.status == :fail }

      # ── checks ─────────────────────────────────────────────────────────

      def check_ruby
        wanted = read(".ruby-version")&.strip&.delete_prefix("ruby-")
        if !Dev::Toolchain.ruby_ok?
          problem("Ruby #{RUBY_VERSION}", "GemStack needs Ruby #{Dev::Toolchain::MIN_RUBY} or newer — " \
                                          "#{Dev::Toolchain.ruby_hint(wanted.to_s.empty? ? "3.4" : wanted)}")
        elsif wanted && !wanted.empty? && !RUBY_VERSION.start_with?(wanted)
          caution("Ruby #{RUBY_VERSION}", "the app pins #{wanted} (.ruby-version) — #{Dev::Toolchain.ruby_hint(wanted)}")
        else
          pass("Ruby #{RUBY_VERSION}#{" (YJIT available)" if defined?(RubyVM::YJIT)}")
        end
      end

      def check_node
        return unless File.directory?(path("frontend"))

        node = Dev::Toolchain.node(@run)
        wanted = read(".node-version")&.strip || read(".nvmrc")&.strip || Dev::Toolchain::LTS_NODE
        if node.nil?
          problem("Node.js not found", Dev::Toolchain.node_hint(wanted, nil))
        elsif !Dev::Toolchain.node_ok?(node[:version])
          problem("Node.js #{node[:version]} (#{node[:path]})",
                  "Next.js 16 needs #{Dev::Toolchain::MIN_NODE.join(".")}+ — " \
                  "#{Dev::Toolchain.node_hint(wanted, Dev::Toolchain.node_manager(node[:path]))}")
        else
          pass("Node.js #{node[:version]}")
        end
      end

      def check_frontend_dependencies
        return unless File.directory?(path("frontend"))

        if File.file?(path("frontend/node_modules/.package-lock.json"))
          lock = path("frontend/package-lock.json")
          stale = File.file?(lock) && File.mtime(lock) > File.mtime(path("frontend/node_modules/.package-lock.json"))
          if stale
            caution("frontend dependencies",
                    "package-lock.json changed — run: cd frontend && npm install")
          else
            pass("frontend dependencies installed")
          end
        else
          problem("frontend dependencies missing", "run: cd frontend && npm install")
        end
      end

      # Secrets committed to git stay in its history (and in every clone).
      def check_boot
        ENV["GEMSTACK_ENV"] = "production" if @production
        ENV["GEMSTACK_ENV"] ||= "development"
        Project.load_config!(@root)
        config = GemStack.config
        config.reload_code = false
        config.eager_load = false
        config.logger.output = nil
        config.db.log_queries = false if config.respond_to?(:db)
        GemStack.boot!
        pass("application boots (#{GemStack.env}, #{GemStack.application.routes.size} routes)")
        true
      rescue StandardError, ScriptError => e
        problem("application fails to boot: #{e.class}: #{e.message.lines.first&.strip}", location(e))
        false
      end

      def check_database
        return true unless defined?(GemStack::DB)

        settings = GemStack::DB.settings
        where = "#{GemStack::DB::Configuration.describe(settings)}, from #{settings[:source]}"
        if settings[:adapter] == "sqlite" && !GemStack::DB::Tasks.exists?(settings)
          problem("SQLite database file missing (#{where})", "run: gemstack db:create")
          return false
        end
        GemStack::DB.connection.test_connection
        pass("database reachable (#{where})")
        true
      rescue StandardError, LoadError => e
        message = e.message.lines.first.to_s.strip
        message = message.split(/FATAL:\s*/, 2).last if message.include?("FATAL:")
        hint = if message.match?(/does not exist|Unknown database/) then "run: gemstack db:create"
               elsif e.is_a?(GemStack::ConfigurationError) then "fix config/database.yml or DATABASE_URL"
               else "is the database server running? Check config/database.yml or DATABASE_URL (#{where})"
               end
        problem("database: #{message}", hint)
        false
      end

      # MySQL/SQLite apps: a jobs worker is a separate process, and the memory
      # broker can't carry its broadcasts to the web server.
      def check_realtime_broker
        return unless defined?(GemStack::Realtime) && defined?(GemStack::Jobs) && GemStack::Jobs.database_queue?
        return unless GemStack.config.realtime.broker.to_s == "memory" && jobs_used?

        caution("realtime uses the in-process memory broker",
                "broadcasts from jobs won't reach the web server — set config.realtime.broker = :redis (REDIS_URL)")
      end

      def check_migrations_and_jobs
        pending = GemStack::DB::Migrator.new.pending
        if pending.empty?
          pass("migrations up to date")
        else
          caution("#{pending.size} pending migration(s)", "run: gemstack db:migrate")
        end
        return unless defined?(GemStack::Jobs) && GemStack::Jobs.database_queue?
        return unless jobs_used?

        if GemStack::DB.connection.table_exists?(:gemstack_jobs)
          pass("jobs table present")
        elsif pending.empty?
          problem("background jobs are used but the gemstack_jobs table is missing",
                  "run: gemstack jobs:install && gemstack db:migrate")
        end
      end

      def check_cache
        return unless GemStack.config.respond_to?(:cache) && GemStack.config.cache.store.to_s == "redis"

        GemStack.cache.write("gemstack:doctor", 1, expires_in: 5)
        pass("Redis cache reachable")
      rescue StandardError => e
        problem("Redis cache: #{e.message.lines.first&.strip}", "is Redis running? Check REDIS_URL")
      end

      def check_contract
        return unless File.directory?(path("frontend"))

        contract = Contract.build(GemStack.application)
        report = Contract.write(contract, root: @root, dry_run: true)
        changed = report[:written] + report[:removed]
        if changed.empty?
          pass("TypeScript contract up to date")
        else
          caution("TypeScript contract out of date (#{changed.size} file(s))",
                  "run: gemstack contract (gemstack dev does it on save)")
        end
        contract[:warnings].first(3).each { |message| caution("contract: #{message}", nil) }
      rescue StandardError => e
        caution("contract could not be built: #{e.message.lines.first&.strip}", "run: gemstack contract")
      end

      def check_production_settings
        secret = GemStack.config.secret_key_base.to_s
        if secret.empty? then problem("SECRET_KEY_BASE is not set", "generate one: openssl rand -hex 64")
        elsif secret.length < 64 then problem("SECRET_KEY_BASE is too short", "use: openssl rand -hex 64")
        else pass("SECRET_KEY_BASE is set")
        end
        check_production_database if defined?(GemStack::DB)
        if defined?(GemStack::Mail) && GemStack.config.mail.delivery.to_s == "smtp"
          env_check("SMTP_URL", "e.g. smtp://user:password@smtp.example.com:587")
        end
        env_check("APP_URL", "the frontend's public URL, used in email links") if defined?(GemStack::Auth)
        check_storage_settings if defined?(GemStack::Storage)
        return unless GemStack.config.respond_to?(:cache) && GemStack.config.cache.store.to_s == "redis"

        env_check("REDIS_URL", "the Redis used by the cache")
      end

      def check_production_database
        settings = GemStack::DB.settings
        if settings[:source].start_with?("default")
          problem("no production database configured",
                  "set DATABASE_URL, or a production section in config/database.yml")
        elsif settings[:adapter] == "sqlite"
          caution("SQLite in production (#{settings[:database]})",
                  "PostgreSQL is recommended: add gem \"pg\" and set DATABASE_URL=postgres://… — SQLite only " \
                  "suits one server, with the file on a persistent volume and backups")
        else
          pass("production database: #{GemStack::DB::Configuration.describe(settings)} (#{settings[:source]})")
        end
      end

      def check_storage_settings
        return unless GemStack.config.storage.service.to_s == "s3"

        env_check("S3_BUCKET", "the bucket uploads go to")
        begin
          require "aws-sdk-s3"
          pass("aws-sdk-s3 available")
        rescue LoadError
          problem("storage uses S3 but aws-sdk-s3 isn't installed", "add gem \"aws-sdk-s3\" to the Gemfile")
        end
      end

      def check_port
        port = Integer(ENV.fetch("PORT", 3000))
        TCPServer.new("127.0.0.1", port).close
        pass("port #{port} is free for gemstack dev")
      rescue Errno::EADDRINUSE
        caution("port #{port} is in use", "stop the other process, or run: PORT=#{port + 1} gemstack dev")
      rescue ArgumentError, SystemCallError
        nil
      end

      private

      def header
        @output.puts("GemStack doctor · #{File.basename(@root)}#{" · production settings" if @production}\n\n")
      end

      def summary
        failures = results.count { |r| r.status == :fail }
        warnings = results.count { |r| r.status == :warn }
        line = if failures.zero? && warnings.zero? then paint("Everything looks good.", 32)
               else
                 [(paint("#{failures} problem(s)", 31) if failures.positive?),
                  (paint("#{warnings} warning(s)", 33) if warnings.positive?)].compact.join(", ")
               end
        @output.puts("\n#{line}")
      end

      def record(status, title, hint)
        @results << Result.new(status, title, hint)
        symbol = { ok: paint("✓", 32), warn: paint("!", 33), fail: paint("✗", 31) }.fetch(status)
        @output.puts("  #{symbol} #{title}")
        @output.puts("      → #{hint}") if hint
      end

      def pass(title) = record(:ok, title, nil)
      def caution(title, hint) = record(:warn, title, hint)
      def problem(title, hint) = record(:fail, title, hint)

      def env_check(name, hint)
        ENV.fetch(name, "").strip.empty? ? problem("#{name} is not set", hint) : pass("#{name} is set")
      end

      def jobs_used?
        Generator.background_work?(@root)
      end

      def location(error)
        frame = Array(error.backtrace_locations || error.backtrace).map(&:to_s).find { |line| line.start_with?(@root) }
        frame ? "at #{frame.delete_prefix("#{@root}/")}" : "run `gemstack server` to see the full error"
      end

      def redact(url) = url.to_s.sub(%r{//([^:/@]+):[^@]+@}, '//\1:***@')
      def path(relative) = File.join(@root, relative)
      def read(relative) = File.file?(path(relative)) ? File.read(path(relative)) : nil
      def paint(text, code) = @color ? "\e[#{code}m#{text}\e[0m" : text
    end
  end
end
