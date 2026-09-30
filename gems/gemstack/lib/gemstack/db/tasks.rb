# frozen_string_literal: true

require "fileutils"

module GemStack
  module DB
    # Database lifecycle used by `gemstack db:*`, for every adapter:
    # PostgreSQL and MySQL through a server connection without the database,
    # SQLite by creating or deleting the file.
    #
    # Each method takes resolved settings (DB.settings, the default) or a URL.
    module Tasks
      module_function

      def settings_for(target)
        target.is_a?(String) ? Configuration.from_url(target, root: GemStack.config.root) : target.except(:source)
      end

      # The database name (SQLite: the file, relative to the app).
      def database_name(target = DB.settings)
        name = settings_for(target)[:database].to_s
        name.delete_prefix("#{GemStack.config.root}/")
      end

      def exists?(target = DB.settings)
        settings = settings_for(target)
        name = settings[:database].to_s
        case settings[:adapter]
        when "sqlite" then name == ":memory:" || File.file?(name)
        when "postgres" then with_server(settings) { |db| db[:pg_database].where(datname: name).any? }
        else with_server(settings) { |db| db[Sequel[:information_schema][:schemata]].where(schema_name: name).any? }
        end
      end

      # Returns :created or :exists.
      def create(target = DB.settings)
        settings = settings_for(target)
        return :exists if exists?(settings)

        name = settings[:database].to_s
        case settings[:adapter]
        when "sqlite"
          FileUtils.mkdir_p(File.dirname(name))
          Sequel.connect(**settings, test: true, keep_reference: false).disconnect # creates the file
        when "postgres"
          with_server(settings) { |db| db.run("CREATE DATABASE #{db.literal(Sequel.identifier(name))}") }
        else
          with_server(settings) do |db|
            db.run("CREATE DATABASE #{db.literal(Sequel.identifier(name))} " \
                   "CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci")
          end
        end
        :created
      end

      # Refuses outside development/test unless GEMSTACK_ALLOW_DB_DROP=1.
      def drop(target = DB.settings)
        unless GemStack.env.local? || ENV["GEMSTACK_ALLOW_DB_DROP"] == "1"
          raise Error, "refusing to drop the #{GemStack.env} database; set GEMSTACK_ALLOW_DB_DROP=1 to confirm"
        end

        settings = settings_for(target)
        return :missing unless exists?(settings)

        DB.disconnect
        name = settings[:database].to_s
        case settings[:adapter]
        when "sqlite" then FileUtils.rm_f(["", "-wal", "-shm", "-journal"].map { |suffix| "#{name}#{suffix}" })
        when "postgres"
          with_server(settings) { |db| db.run("DROP DATABASE #{db.literal(Sequel.identifier(name))} WITH (FORCE)") }
        else with_server(settings) { |db| db.run("DROP DATABASE #{db.literal(Sequel.identifier(name))}") }
        end
        :dropped
      end

      def seed(path = GemStack.root.join(DB.config.seeds_path))
        return false unless File.file?(path)

        load path.to_s
        true
      end

      # A connection to the server itself: PostgreSQL's "postgres" maintenance
      # database, or MySQL without a default database.
      def with_server(settings)
        server = settings.merge(database: settings[:adapter] == "postgres" ? "postgres" : nil).compact
        db = Sequel.connect(**server, max_connections: 1, test: true, keep_reference: false)
        yield db
      ensure
        db&.disconnect
      end
    end
  end
end
