# frozen_string_literal: true

require "thor"
require "gemstack/core"

module GemStack
  # The `gemstack` command.
  class CLI < Thor
    require_relative "cli/add_next_steps"
    require_relative "cli/project"
    require_relative "cli/generator"
    require_relative "cli/generation_manifest"
    require_relative "cli/migration_status"
    require_relative "cli/migration_git_status"
    require_relative "cli/destroy_generator"
    require_relative "cli/app_generator"
    require_relative "cli/controller_generator"
    require_relative "cli/resource_spec"
    require_relative "cli/migration_changes"
    require_relative "cli/resource_generator"
    require_relative "cli/migration_generator"
    require_relative "cli/job_generator"
    require_relative "cli/policy_generator"
    require_relative "cli/doctor"
    require_relative "cli/deploy_generator"
    require_relative "cli/add_generator"
    require_relative "cli/update_generator"
    require_relative "cli/commands/db"
    require_relative "cli/commands/jobs"
    require_relative "cli/console_methods"
    require_relative "cli/helpers"

    # Commands that need the application's bundle (see Project.ensure_bundle!).
    class << self
      attr_accessor :argv

      def start(given_args = ARGV, config = {})
        self.argv = given_args.dup
        super
      end

      def exit_on_failure? = true

      # Show the executable the user invoked in Thor's help output.
      def basename = File.basename($PROGRAM_NAME) == "gsk" ? "gsk" : "gemstack"
    end

    GENERATORS = "resource, model, migration, controller, job, policy, deploy"

    map %w[-v --version] => :version
    map "s" => :server, "c" => :console, "t" => :test, "g" => :generate, "d" => :destroy

    desc "new NAME", "Create a new GemStack application (Ruby API + Next.js frontend)"
    long_desc <<~DESC
      Creates NAME/ with a Ruby API, a Next.js + TypeScript frontend and no business resources.
      Then: cd NAME && gemstack dev
    DESC
    method_option :skip_install, type: :boolean, default: false, desc: "Don't run bundle install / npm install"
    method_option :skip_git, type: :boolean, default: false, desc: "Don't initialise a git repository"
    method_option :skip_frontend, type: :boolean, default: false, desc: "API only: no Next.js frontend"
    method_option :database, aliases: "-d", type: :string, default: "sqlite3",
                             desc: "sqlite3 (default), postgresql, mysql2 or trilogy"
    method_option :skip_database, type: :boolean, default: false, desc: "No database (no models, no gemstack/db)"
    method_option :gemstack_path, type: :string, desc: "Use GemStack from a local checkout (its gems/ directory)"
    def new(name)
      AppGenerator.new(name, options.transform_keys(&:to_sym)).run
    end

    desc "dev", "Run the application: Next.js + Ruby API behind one origin (http://localhost:3000)"
    def dev
      root = Project.ensure_bundle!(self.class.argv)
      ENV["GEMSTACK_ENV"] ||= "development"
      Project.load_config!(root)
      require "gemstack/dev"
      Dev::Supervisor.new(root: root).run
    rescue GemStack::Error => e
      abort("gemstack dev: #{e.message}")
    end

    desc "server", "Run only the Ruby API with Puma (alias: s)"
    method_option :port, aliases: "-p", type: :numeric, desc: "Port (default: GEMSTACK_API_PORT or 4000)"
    def server
      root = Project.ensure_bundle!(self.class.argv)
      env = {}
      env["GEMSTACK_API_PORT"] = options[:port].to_s if options[:port]
      env["GEMSTACK_ENV"] = options[:environment] if options[:environment]
      exec(env, "bundle", "exec", "puma", "-C", File.join(root, "config/puma.rb"))
    end

    desc "routes", "List API routes"
    method_option :grep, aliases: "-g", type: :string, desc: "Only routes matching this text"
    def routes
      root = Project.ensure_bundle!(self.class.argv)
      use_environment!
      Project.load_config!(root)
      GemStack.config.reload_code = false
      GemStack.config.logger.level = :warn
      GemStack.config.db.log_queries = false if GemStack.config.respond_to?(:db)
      rows = GemStack.boot!.routes.map { |r| [r.verb, r.path, r.target] }
      rows.select! { |row| row.join(" ").include?(options[:grep]) } if options[:grep]
      return say("No routes defined. Add them to config/routes.rb.") if rows.empty?

      print_table(rows)
    end

    desc "console", "Start an IRB session with the application loaded (alias: c)"
    def console
      root = Project.ensure_bundle!(self.class.argv)
      use_environment!
      Project.load_config!(root)
      GemStack.boot!

      require "irb"
      TOPLEVEL_BINDING.receiver.extend(ConsoleMethods)

      say("GemStack #{GemStack::VERSION} console (#{GemStack.env}). `GemStack.application.reload!` reloads code.")

      ARGV.clear
      IRB.start
    end

    desc "test [FILES...]", "Run the Ruby test suite (alias: t)"
    def test(*files)
      root = Project.ensure_bundle!(self.class.argv)
      files = Dir.glob("test/**/*_test.rb", base: root).sort if files.empty?
      return say("No tests found in test/.") if files.empty?

      loader = "ARGV.each { |f| require File.expand_path(f) }"
      exec({ "GEMSTACK_ENV" => "test" }, RbConfig.ruby, "-Itest", "-e", loader, *files)
    end

    desc "generate GENERATOR NAME [ARGS]",
         "Generate code (alias: g). Generators: resource, model, migration, controller, job, policy, deploy"
    long_desc <<~DESC
      gemstack generate resource Product name:string price:decimal description:text:optional active:boolean
        Full vertical slice: migration, model, serializer, controller, routes, tests,
        TypeScript client (via the contract) and Next.js pages. Without fields it asks interactively.
        --api-only            backend only
        --frontend-only       Next.js pages/components only (for an existing backend resource)
        --actions=index,show  a subset of index,show,create,update,destroy (default: all = --crud)
        --skip-tests

      gemstack generate model Product name:string price:decimal
        Migration, model, serializer and model test.

      gemstack generate migration AddSkuToProducts sku:string:unique

      gemstack generate controller Products index show publish

      gemstack generate job SendWelcomeEmail [QUEUE]
        app/jobs/send_welcome_email.rb + test (+ the gemstack_jobs migration the first time)

      gemstack generate policy Order
        app/policies/order_policy.rb + test (needs gemstack add auth)

      gemstack generate deploy
        Kamal: Dockerfile, config/deploy.yml, .kamal/secrets, bin/docker-entrypoint, .dockerignore

      Field syntax: name:type[:optional][:unique][:index]. Types: #{ResourceSpec::TYPES.join(", ")}.
      Fields are required unless marked :optional.
    DESC
    method_option :api_only, type: :boolean, default: false, desc: "resource: backend only"
    method_option :frontend_only, type: :boolean, default: false, desc: "resource: frontend only"
    method_option :crud, type: :boolean, default: false, desc: "resource: all REST actions (the default)"
    method_option :actions, type: :string, desc: "resource: comma-separated subset of REST actions"
    method_option :skip_tests, type: :boolean, default: false
    method_option :skip_contract, type: :boolean, default: false, desc: "don't regenerate the TypeScript contract"
    method_option :force, type: :boolean, default: false, desc: "overwrite existing files"
    def generate(generator = nil, name = nil, *args)
      root = Project.root!
      case generator
      when "controller"
        abort("Usage: gemstack generate controller NAME [ACTIONS...]") unless name
        ControllerGenerator.new(name, args, root: root, force: options[:force]).run
      when "model" then generate_model(root, name, args)
      when "resource" then generate_resource(root, name, args)
      when "migration"
        abort("Usage: gemstack generate migration NAME [field:type ...]") unless name
        MigrationGenerator.new(name, args, root: root).run
      when "job" then generate_job(root, name, args)
      when "policy" then generate_policy(root, name)
      when "deploy"
        DeployGenerator.new(root: root, force: options[:force]).run
        say("\nNext: bundle install, edit the CHANGE lines in config/deploy.yml, then " \
            "bundle exec kamal setup — docs/deployment.md")
      when nil then abort("Usage: gemstack generate GENERATOR NAME. Generators: #{GENERATORS}")
      else abort("Unknown generator #{generator.inspect}. Available: #{GENERATORS}")
      end
    end

    desc "destroy GENERATOR NAME", "Remove tracked generated code (alias: d): model, controller, resource"
    DestroyGenerator.configure(self)
    def destroy(generator = nil, name = nil)
      DestroyGenerator.invoke(generator, name, cli: self) { |root| refresh_contract(root) }
    end

    desc "add FEATURE", "Add an optional module to this app: realtime, auth, storage"
    long_desc <<~DESC
      gemstack add realtime
        Adds gemstack-realtime, config/channels.rb, frontend/lib/gemstack/realtime.ts and test helpers.
      gemstack add auth
        Sign up, log in/out, password reset and email verification, API tokens and policies:
        migrations (users, sessions, auth_tokens), User model, controllers, routes, AuthMailer,
        tests and Next.js pages (/login, /signup, /forgot-password, /reset-password, /verify-email, /account).
      gemstack add storage
        File uploads straight from the browser to disk (development) or S3: config, uploads
        controller, routes and frontend/lib/upload.ts.
    DESC
    method_option :skip_install, type: :boolean, default: false
    method_option :skip_contract, type: :boolean, default: false, desc: "don't regenerate the TypeScript contract"
    def add(feature)
      root = Project.root!
      AddGenerator.new(feature, root: root, install: !options[:skip_install]).run
      refresh_contract(root) if %w[auth
                                   storage].include?(feature) && !options[:skip_install] && !options[:skip_contract]
      say("\n#{AddNextSteps::STEPS.fetch(feature)}")
    end

    desc "doctor", "Check that this app can run (Ruby, Node, database, migrations, contract…) and how to fix it"
    long_desc <<~DESC
      gemstack doctor               checks for development
      gemstack doctor --production  also checks the settings a deploy needs (run it with the production environment variables: SECRET_KEY_BASE, DATABASE_URL, SMTP_URL…)
    DESC
    method_option :production, type: :boolean, default: false
    def doctor
      root = Project.ensure_bundle!(self.class.argv)
      exit(1) unless Doctor.new(root: root, production: options[:production]).run.ok?
    end

    desc "version", "Print the GemStack version"
    def version = say("GemStack #{GemStack::VERSION}")

    desc "update [VERSION]", "Update GemStack to the latest version or specified VERSION"
    long_desc <<~DESC
      Updates the GemStack version in your Gemfile and runs bundle update.
      Examples:
        gemstack update          # Update to latest GemStack version
        gemstack update 0.3.5    # Update to specific version
    DESC
    def update(version = nil)
      target_version = version || GemStack::VERSION
      unless target_version == GemStack::VERSION
        say("Warning: You are running gemstack version #{GemStack::VERSION} but trying to update to #{target_version}")
        say("This command should be run from within the GemStack framework itself to update to #{target_version}")
        say("For updating an application's GemStack dependency, run this command from the application directory")
        return
      end

      generator = UpdateGenerator.new
      generator.run
    end

    include Helpers
  end
end
