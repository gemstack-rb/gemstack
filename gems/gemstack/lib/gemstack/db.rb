# frozen_string_literal: true

require "sequel"
require "json"
require "gemstack/core"
require "gemstack/schema"

require_relative "db/json_compat"
require_relative "db/configuration"
require_relative "db/schema_types"

module GemStack
  # SQL databases through Sequel: PostgreSQL, MySQL
  # (mysql2 or trilogy) and SQLite, configured by config/database.yml or
  # DATABASE_URL. Load it with `require "gemstack/db"` in config/app.rb and add the driver gem
  # (pg, mysql2, trilogy or sqlite3) to the Gemfile — `gemstack new` does.
  #
  #   GemStack.db[:products].where(active: true).count     # the Sequel::Database
  #   GemStack.transaction { order.save; payment.save }
  module DB
    class Config < Settings
      # An explicit database URL; wins over DATABASE_URL and config/database.yml
      # (see DB::Configuration). Test uses TEST_DATABASE_URL, never DATABASE_URL,
      # so a development database from .env can't be wiped by the test suite.
      setting :url, default: nil
      # One connection per server thread by default (database.yml `pool:` wins).
      setting :pool_size, default: lambda {
        Integer(ENV.fetch("GEMSTACK_DB_POOL") { ENV.fetch("GEMSTACK_MAX_THREADS", 5) })
      }
      setting :pool_timeout, default: 5
      setting :migrations_path, default: "db/migrations"
      setting :seeds_path, default: "db/seeds.rb"
      setting :log_queries, default: -> { GemStack.env.development? }
      # Queries slower than this are logged at WARN in every environment.
      setting :slow_query_ms, default: 500
      # Server-side statement timeout in ms (nil = the database's default).
      # PostgreSQL: statement_timeout; MySQL: max_execution_time (SELECTs); SQLite: none.
      setting :statement_timeout, default: nil
      # Sequel extensions to load; nil = pg_json + pg_array on PostgreSQL, none elsewhere.
      setting :extensions, default: nil
      # Extra options passed to Sequel.connect.
      setting :options, default: {}
    end

    class RecordNotFound < NotFound; end

    # Stored and compared in UTC on every adapter (MySQL DATETIME and SQLite
    # text have no time zone); PostgreSQL timestamptz is unaffected.
    Sequel.database_timezone = :utc

    # Adapts Sequel's logging to the GemStack logger: SQL at DEBUG only when
    # config.db.log_queries is on, slow queries at WARN, and failures of the
    # existence probes Sequel runs on purpose (table_exists?, model setup
    # before a migration) are not reported as errors.
    class QueryLogger
      PROBE = /: SELECT (?:NULL AS [`"']nil[`"'] FROM \S+ LIMIT 1|\* FROM \S+ LIMIT 0)\z/

      def initialize(logger, queries:)
        @logger = logger
        @queries = queries
      end

      def debug(message) = (@logger.debug(message) if @queries)
      def info(message) = @logger.info(message)
      def warn(message) = @logger.warn(message)
      def error(message) = (@logger.error(message) unless PROBE.match?(message.to_s))
    end

    @mutex = Mutex.new

    class << self
      def config = GemStack.config.db

      def connection
        @connection || @mutex.synchronize { @connection ||= connect }
      end

      def connected? = !@connection.nil?

      # The resolved connection settings (a Hash; see DB::Configuration).
      def settings = @settings ||= Configuration.resolve

      # "postgres", "mysql2", "trilogy" or "sqlite".
      def adapter = settings[:adapter]
      def postgres?(db = nil) = type(db) == :postgres
      def mysql?(db = nil) = type(db) == :mysql
      def sqlite?(db = nil) = type(db) == :sqlite

      # Sequel's database type (:postgres, :mysql, :sqlite) — from the
      # connection when there is one, so no query is needed.
      def type(db = nil)
        db ||= @connection
        return db.database_type if db

        { "postgres" => :postgres, "mysql2" => :mysql, "trilogy" => :mysql, "sqlite" => :sqlite }.fetch(adapter)
      end

      # Builds the Sequel::Database. Connections are opened lazily, so an
      # unavailable database doesn't prevent the application from booting.
      def connect(target = settings)
        target = Configuration.from_url(target, root: GemStack.config.root) if target.is_a?(String)
        opts = target.except(:source)
        options = { max_connections: opts.delete(:max_connections) || config.pool_size,
                    pool_timeout: config.pool_timeout, test: false, keep_reference: false }
        options.merge!(adapter_options(opts[:adapter], opts[:database]))
        db = open_database(opts.merge(options).merge(config.options))
        configure(db)
        Sequel::Model.db = db
        db
      end

      # Closes pooled connections (e.g. before Puma forks workers). The
      # Database object stays in place and reconnects lazily: models hold a
      # reference to it, so replacing it would split them from GemStack.db.
      def disconnect
        @connection&.disconnect
      end

      def transaction(**, &) = connection.transaction(**, &)

      # Forgets the resolved settings and the connection (tests, console).
      def reset!
        @connection&.disconnect
        @connection = nil
        @settings = nil
      end

      # True when the table isn't there — one catalog query, nothing logged
      # (Sequel's table_exists? probes with a failing SELECT).
      def table_missing?(db, table)
        name = table.to_s
        case db.database_type
        when :postgres then db.get(Sequel.function(:to_regclass, db.literal(table))).nil?
        when :mysql
          db[Sequel[:information_schema][:tables]].where(table_schema: Sequel.function(:database),
                                                         table_name: name).empty?
        when :sqlite then db[:sqlite_master].where(type: %w[table view], name: name).empty?
        else !db.table_exists?(table)
        end
      end

      private

      def configure(db)
        extensions = config.extensions || (postgres?(db) ? %i[pg_json pg_array] : [])
        db.extension(*extensions) unless extensions.empty?
        db.log_warn_duration = config.slow_query_ms / 1000.0 if config.slow_query_ms
        db.loggers << QueryLogger.new(GemStack.logger, queries: config.log_queries)
        db.sql_log_level = :debug
      end

      def open_database(options)
        Sequel.connect(**options)
      rescue Sequel::AdapterNotFound, LoadError => e
        gem_name = Configuration::DRIVER_GEMS.fetch(options[:adapter], options[:adapter])
        raise ConfigurationError, "#{options[:adapter]} needs gem \"#{gem_name}\" in the Gemfile (#{e.message})"
      end

      def adapter_options(adapter, database)
        timeout = config.statement_timeout && Integer(config.statement_timeout)
        case adapter
        when "postgres" then timeout ? { connect_sqls: ["SET statement_timeout = #{timeout}"] } : {}
        when "mysql2", "trilogy"
          sqls = timeout ? ["SET SESSION max_execution_time = #{timeout}"] : []
          { encoding: "utf8mb4", connect_sqls: sqls }
        when "sqlite"
          # Several Puma threads share the file: wait for the write lock instead
          # of failing, and let readers work while one connection writes.
          sqls = database == ":memory:" ? [] : ["PRAGMA journal_mode = WAL", "PRAGMA synchronous = NORMAL"]
          { timeout: 5_000, connect_sqls: sqls }
        else {}
        end
      end
    end
  end

  # A model base class bound to an explicit table, like Sequel::Model(:table):
  #   class Item < GemStack::Model(:inventory_items)
  def self.Model(source) = Model.Model(source) # rubocop:disable Naming/MethodName

  class << self
    def db = DB.connection
    def transaction(**, &) = DB.transaction(**, &)
  end
end

require_relative "db/model"
require_relative "db/errors"
require_relative "db/migrator"
require_relative "db/tasks"

GemStack::Config.namespace(:db, GemStack::DB::Config)

GemStack::Plugins.register(:db) do |app|
  GemStack::DB.connection
  app.on_shutdown { GemStack::DB.disconnect } if app.respond_to?(:on_shutdown)

  # A friendly nudge in development; never blocks boot.
  if GemStack.env.development?
    begin
      pending = GemStack::DB::Migrator.new.pending
      unless pending.empty?
        GemStack.logger.warn("#{pending.size} pending migration(s) — run `gemstack db:migrate`",
                             first: pending.first.file)
      end
    rescue Sequel::Error
      nil # database not reachable yet; requests will report it
    end
  end
end
