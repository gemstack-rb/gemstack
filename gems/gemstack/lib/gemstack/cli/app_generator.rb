# frozen_string_literal: true

require "gemstack/dev"

module GemStack
  class CLI < Thor
    # `gemstack new NAME` — a Ruby API + Next.js application containing the
    # framework infrastructure and deliberately no business resources.
    class AppGenerator < Generator
      NAME = /\A[a-z][a-z0-9_-]*\z/
      # `--database` values (Rails' names) and aliases.
      DATABASES = { "sqlite3" => "sqlite3", "sqlite" => "sqlite3", "postgresql" => "postgresql",
                    "postgres" => "postgresql", "pg" => "postgresql", "mysql2" => "mysql2", "mysql" => "mysql2",
                    "trilogy" => "trilogy" }.freeze
      DRIVERS = { "sqlite3" => ["sqlite3", "~> 2.0"], "postgresql" => ["pg", "~> 1.5"],
                  "mysql2" => ["mysql2", "~> 0.5"], "trilogy" => ["trilogy", "~> 2.9"] }.freeze

      # The gems/ directory of the GemStack checkout this CLI runs from, if any.
      CHECKOUT = File.expand_path("../../../..", __dir__)

      attr_reader :name, :module_name, :destination, :gemstack_path, :api_path

      def initialize(name, options = {}, output: $stdout)
        super(output: output)
        @name = File.basename(name.to_s)
        @destination = File.expand_path(name.to_s)
        @options = options
        @module_name = Inflector.camelize(@name.tr("-", "_"))
        @gemstack_path = options[:gemstack_path] ? File.expand_path(options[:gemstack_path]) : detect_checkout
        @api_path = "/api"
        self.templates = options[:templates] if options[:templates]
      end

      # (gemstack update renders older releases' templates with their own values.)
      def version = @options[:version] || GemStack::VERSION

      # Pins the app to the Ruby that generated it, in files every version
      # manager reads (.ruby-version: rbenv, rvm, chruby, asdf, mise;
      # .tool-versions: asdf, mise), and Node.js likewise (.node-version,
      # .nvmrc, .tool-versions).
      def ruby_version = @options[:ruby_version] || RUBY_VERSION
      def node_version = @node_version ||= @options[:node_version] || Dev::Toolchain.pinned_node_version
      def frontend? = !@options[:skip_frontend]
      def database? = !@options[:skip_database]

      # sqlite3 (default), postgresql, mysql2 or trilogy.
      def database_adapter
        @database_adapter ||= DATABASES.fetch(@options[:database].to_s.downcase.then do |d|
          d.empty? ? "sqlite3" : d
        end) do
          raise Thor::Error,
                "Unknown --database #{@options[:database].inspect}. Use: sqlite3, postgresql, mysql2, trilogy"
        end
      end

      def driver_gem = DRIVERS.fetch(database_adapter).first
      def driver_version = DRIVERS.fetch(database_adapter).last
      def database_name = name.tr("-", "_")

      def run
        validate!
        database_adapter if database? # fail early on an unknown --database
        @output.puts("Creating GemStack application #{name} in #{destination}")
        render_directory("app", destination, skip: lambda { |rel|
          (!database? && (rel.start_with?("db/", "app/models/") || rel == "config/database.yml.tt")) ||
            (!frontend? && %w[dot_node-version.tt dot_nvmrc.tt].include?(rel))
        })
        render_directory("frontend", File.join(destination, "frontend")) if frontend?
        install unless @options[:skip_install]
        git_init unless @options[:skip_git]
        summary
        self
      end

      private

      def validate!
        unless NAME.match?(name)
          raise Thor::Error,
                "Invalid name #{name.inspect}: use lowercase letters, digits, - and _, starting with a letter"
        end
        return unless File.exist?(destination) && !Dir.empty?(destination)

        raise Thor::Error, "#{destination} already exists and is not empty"
      end

      def detect_checkout
        File.file?(File.join(CHECKOUT, "gemstack", "gemstack.gemspec")) ? CHECKOUT : nil
      end

      def install
        bundled = run_step("bundle install", destination, "bundle", "install", "--quiet")
        create_database if bundled && database?
        return unless frontend?

        run_step("npm install", File.join(destination, "frontend"), "npm", "install", "--no-fund",
                 "--no-audit")
        # The TypeScript contract, so frontend/lib/api/generated exists from the start.
        run_step("gemstack contract", destination, "bin/gemstack", "contract", "--quiet") if bundled
      end

      # Best effort: a missing or password-protected database server shouldn't fail `new`.
      def create_database
        @output.puts("  #{"run".rjust(9)}  gemstack db:create")
        ok = unbundled { system("bin/gemstack", "db:create", chdir: destination, out: File::NULL, err: File::NULL) }
        return if ok

        @output.puts("  #{"warning".rjust(9)}  couldn't create the database — " \
                     "check config/database.yml (or set DATABASE_URL in .env), then run `gemstack db:create`")
      end

      def git_init
        return if File.directory?(File.join(destination, ".git")) || !system("git --version", out: File::NULL)

        run_step("git init", destination, "git", "init", "--quiet")
      end

      def run_step(label, dir, *command)
        @output.puts("  #{"run".rjust(9)}  #{label}")
        ok = unbundled { system(*command, chdir: dir) }
        @output.puts("  #{"warning".rjust(9)}  `#{label}` failed — run it manually in #{dir}") unless ok
        ok
      end

      # Run child commands with the new app's bundle, not the CLI's.
      def unbundled(&)
        defined?(Bundler) ? Bundler.with_unbundled_env(&) : yield
      end

      def summary
        @output.puts <<~TEXT

          GemStack application #{name} created.

            cd #{name}
            gemstack dev        # → http://localhost:3000

          Next: gemstack generate resource Product name:string price:decimal
          Useful commands: gemstack routes · gemstack test · gemstack console · gemstack db:migrate
        TEXT
      end
    end
  end
end
