# frozen_string_literal: true

module GemStack
  class CLI < Thor
    map "db:create" => :db_create, "db:drop" => :db_drop, "db:migrate" => :db_migrate,
        "db:rollback" => :db_rollback, "db:seed" => :db_seed, "db:setup" => :db_setup,
        "db:status" => :db_status, "db:reset" => :db_reset

    class_option :environment, aliases: "-e", type: :string, desc: "Environment (default: GEMSTACK_ENV or development)"

    desc "db:create", "Create the database (config/database.yml or DATABASE_URL)"
    def db_create
      with_database do
        result = DB::Tasks.create
        say("#{result == :created ? "Created" : "Already exists"}: #{DB::Tasks.database_name}")
      end
    end

    desc "db:drop", "Drop the database (refused in production unless GEMSTACK_ALLOW_DB_DROP=1)"
    def db_drop
      with_database do
        result = DB::Tasks.drop
        say("#{result == :dropped ? "Dropped" : "Does not exist"}: #{DB::Tasks.database_name}")
      end
    end

    desc "db:migrate", "Apply pending migrations (--target VERSION to migrate up or down to a version)"
    method_option :target, type: :numeric
    def db_migrate
      with_database do
        changed = DB::Migrator.new.migrate(target: options[:target])
        changed.empty? ? say("No pending migrations.") : changed.sort.each { |file| say("  migrated  #{file}") }
      end
    end

    desc "db:rollback", "Revert the last migration (--steps N for more)"
    method_option :steps, type: :numeric, default: 1
    def db_rollback
      with_database do
        reverted = DB::Migrator.new.rollback(steps: options[:steps])
        if reverted.empty?
          say("Nothing to roll back.")
        else
          reverted.sort.reverse_each do |file|
            say("  reverted  #{file}")
          end
        end
      end
    end

    desc "db:status", "List migrations and whether they are applied"
    def db_status
      with_database do
        rows = DB::Migrator.new.status.map { |m| [m.applied ? "up" : "down", m.version.to_s, m.name] }
        if rows.empty?
          say("No migrations in #{DB.config.migrations_path}.")
        else
          print_table([%w[Status Version Name],
                       *rows])
        end
      end
    end

    desc "db:seed", "Load db/seeds.rb"
    def db_seed
      with_database(boot: true) do
        DB::Tasks.seed ? say("Seeded from #{DB.config.seeds_path}.") : say("No #{DB.config.seeds_path} found.")
      end
    end

    desc "db:setup", "Create the database, migrate and seed"
    def db_setup
      db_create
      db_migrate
      db_seed
    end

    desc "db:reset", "Drop, recreate, migrate and seed (development/test only)"
    def db_reset
      db_drop
      db_setup
    end

    desc "contract", "Generate TypeScript types, API clients and OpenAPI from the backend"
    method_option :quiet, type: :boolean, default: false
    def contract
      root = Project.ensure_bundle!(self.class.argv)
      ENV["GEMSTACK_ENV"] = options[:environment] || ENV["GEMSTACK_ENV"] || "development"
      Project.load_config!(root)
      require "gemstack/contract"
      GemStack.config.reload_code = false
      GemStack.config.logger.level = :warn
      GemStack.config.db.log_queries = false if GemStack.config.respond_to?(:db)
      contract = Contract.build(GemStack.boot!)
      report = Contract.write(contract, root: root, typescript: File.directory?(File.join(root, "frontend")))
      print_contract_report(report, contract, root)
    rescue Sequel::DatabaseConnectionError => e
      abort("gemstack contract: database unreachable (#{e.message.lines.first.strip}). Models need it to load.")
    end

    no_commands do
      def with_database(boot: false)
        root = Project.ensure_bundle!(self.class.argv)
        ENV["GEMSTACK_ENV"] = options[:environment] || ENV["GEMSTACK_ENV"] || "development"
        Project.load_config!(root)
        unless defined?(GemStack::DB)
          abort("This app doesn't load the database module. Add `require \"gemstack/db\"` to config/app.rb " \
                "(and a config/database.yml) — see docs/database.md.")
        end
        GemStack.config.reload_code = false
        GemStack.config.db.log_queries = false
        GemStack.config.logger.level = :warn # these commands print their own summary
        GemStack.boot! if boot
        yield
      rescue Sequel::DatabaseConnectionError => e
        settings = DB.settings
        abort("Can't connect to #{DB::Configuration.describe(settings)} (from #{settings[:source]}): " \
              "#{e.message.lines.first.strip}\nCheck config/database.yml or DATABASE_URL — see docs/database.md.")
      rescue GemStack::Error => e
        abort(e.message)
      end

      def redact(url) = url.sub(%r{//([^:/@]+):[^@]+@}, '//\1:***@')

      def print_contract_report(report, contract, root)
        rel = ->(path) { path.delete_prefix("#{root}/") }
        report[:written].each { |path| say("  #{"write".rjust(9)}  #{rel.call(path)}") }
        report[:removed].each { |path| say("  #{"remove".rjust(9)}  #{rel.call(path)}") }
        contract[:warnings].each { |w| say("  #{"warning".rjust(9)}  #{w}", :yellow) } unless options[:quiet]
        return if options[:quiet] || !report[:written].empty? || !report[:removed].empty?

        say("Contract up to date (#{contract[:resources].size} resources, #{contract[:types].size} types).")
      end
    end
  end
end
