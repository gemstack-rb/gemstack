# frozen_string_literal: true

require "test_helper"

class DBConfigTest < Minitest::Test
  Configuration = GemStack::DB::Configuration

  def setup
    @root = Dir.mktmpdir
    @saved = %w[DATABASE_URL TEST_DATABASE_URL].to_h { |k| [k, ENV.delete(k)] }
  end

  def teardown
    @saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    FileUtils.rm_rf(@root)
  end

  def resolve(url: nil, env: "test")
    config = GemStack::DB::Config.new
    config.url = url
    Configuration.resolve(config: config, env: GemStack::Environment.new(env), root: @root)
  end

  def database_yml(content)
    FileUtils.mkdir_p("#{@root}/config")
    File.write("#{@root}/config/database.yml", content)
  end

  def test_default_without_database_yml
    previous = GemStack.config.name
    GemStack.config.name = "my-shop"

    assert_equal({ adapter: "postgres", database: "my_shop_test", source: "default (no config/database.yml)" },
                 resolve)
  ensure
    GemStack.config.name = previous
  end

  def test_database_yml_like_rails
    database_yml(<<~YAML)
      default: &default
        adapter: postgresql
        host: localhost
        username: shop
        password: <%= "s3cret" %>
        pool: 7
        schema_search_path: public
      development:
        <<: *default
        database: shop_development
      test:
        <<: *default
        database: shop_test
    YAML

    assert_equal({ adapter: "postgres", host: "localhost", user: "shop", password: "s3cret", max_connections: 7,
                   database: "shop_test", source: "config/database.yml (test)" }, resolve)
  end

  def test_sqlite_paths_are_relative_to_the_app
    database_yml("test:\n  adapter: sqlite3\n  database: db/test.sqlite3\n")

    assert_equal File.join(@root, "db/test.sqlite3"), resolve[:database]
    assert_equal ":memory:", Configuration.from_url("sqlite3::memory:", root: @root)[:database]
    assert_equal "/var/data/app.db", Configuration.from_url("sqlite3:///var/data/app.db", root: @root)[:database]
    assert_equal File.join(@root, "db/x.db"), Configuration.from_url("sqlite3:db/x.db", root: @root)[:database]
  end

  def test_database_url_wins_over_the_yml_but_keeps_its_pool
    database_yml("test:\n  adapter: sqlite3\n  database: db/test.sqlite3\n  pool: 3\n")
    ENV["TEST_DATABASE_URL"] = "mysql2://root:p%40ss@db.local:3307/shop_test?sslmode=required"

    assert_equal({ adapter: "mysql2", host: "db.local", port: 3307, database: "shop_test", user: "root",
                   password: "p@ss", sslmode: "required", max_connections: 3, source: "TEST_DATABASE_URL" }, resolve)
  end

  def test_test_env_ignores_development_database_url
    ENV["DATABASE_URL"] = "postgres:///dev_db"
    ENV["TEST_DATABASE_URL"] = "postgres:///test_db"

    assert_equal "test_db", resolve[:database]
    assert_equal "dev_db", resolve(env: "development")[:database]
  end

  def test_explicit_url_wins
    ENV["TEST_DATABASE_URL"] = "postgres:///test_db"

    assert_equal({ adapter: "trilogy", host: "h", database: "x", source: "config.db.url" }, resolve(url: "trilogy://h/x"))
  end

  def test_yml_url_key_with_overrides
    database_yml("production:\n  url: postgres://u@h/app\n  pool: 12\n")

    assert_equal({ adapter: "postgres", host: "h", database: "app", user: "u", max_connections: 12,
                   source: "config/database.yml (production)" }, resolve(env: "production"))
  end

  def test_errors
    database_yml("development:\n  adapter: oracle\n")

    assert_raises(GemStack::ConfigurationError) { resolve(env: "development") }
    error = assert_raises(GemStack::ConfigurationError) { resolve(env: "staging") }
    assert_includes error.message, "no staging section"
    assert_raises(GemStack::ConfigurationError) { Configuration.from_url("mongodb://x/y", root: @root) }
  end

  def test_describe_hides_passwords
    settings = Configuration.from_url("postgres://me:secret@db:5433/shop", root: @root)

    assert_equal "postgres://me@db:5433/shop", Configuration.describe(settings)
  end

  def test_pool_follows_server_threads
    ENV["GEMSTACK_MAX_THREADS"] = "9"

    assert_equal 9, GemStack::DB::Config.new.pool_size
  ensure
    ENV.delete("GEMSTACK_MAX_THREADS")
  end

  def test_tasks_database_name
    assert_equal "shop_dev", GemStack::DB::Tasks.database_name("postgres://u:p@db.local:5433/shop_dev?sslmode=require")
  end
end

class DBTasksTest < Minitest::Test
  include DBTest

  def test_create_exists_drop
    url = DBTest::URL.sub(%r{/[^/?]+(\?|\z)}, "/gemstack_tasks_probe\\1")
    GemStack::DB::Tasks.drop(url)

    assert_equal :created, GemStack::DB::Tasks.create(url)
    assert_equal :exists, GemStack::DB::Tasks.create(url)
    assert GemStack::DB::Tasks.exists?(url)
    assert_equal :dropped, GemStack::DB::Tasks.drop(url)
    refute GemStack::DB::Tasks.exists?(url)
  end

  def test_drop_refused_in_production
    GemStack.env = "production"

    assert_raises(GemStack::Error) { GemStack::DB::Tasks.drop }
  ensure
    GemStack.env = "test"
  end
end

class MigratorTest < Minitest::Test
  include DBTest

  def setup
    super
    @dir = Dir.mktmpdir
    File.write("#{@dir}/20260101000000_create_gadgets.rb", <<~RUBY)
      Sequel.migration do
        change do
          create_table(:migrator_gadgets) { primary_key :id }
        end
      end
    RUBY
    File.write("#{@dir}/20260102000000_add_name.rb", <<~RUBY)
      Sequel.migration do
        change do
          add_column :migrator_gadgets, :name, String
        end
      end
    RUBY
    @migrator = GemStack::DB::Migrator.new(db, @dir)
    @migrator.migrate(target: 0)
  end

  def teardown
    @migrator&.migrate(target: 0)
    FileUtils.rm_rf(@dir) if @dir
  end

  def test_migrate_status_rollback
    assert_equal 2, @migrator.pending.size
    applied = @migrator.migrate

    assert_equal %w[20260101000000_create_gadgets.rb 20260102000000_add_name.rb], applied.sort
    assert_includes db[:migrator_gadgets].columns, :name
    refute_predicate @migrator, :pending?
    assert_equal ["create_gadgets", true], [@migrator.status.first.name, @migrator.status.first.applied]

    assert_equal ["20260102000000_add_name.rb"], @migrator.rollback
    refute_includes db.schema(:migrator_gadgets, reload: true).map(&:first), :name
    @migrator.rollback(steps: 5)

    refute db.table_exists?(:migrator_gadgets)
  end

  def test_migrate_is_idempotent
    @migrator.migrate

    assert_empty @migrator.migrate
  end
end

class QueryLoggerTest < Minitest::Test
  def logger(queries)
    @io = StringIO.new
    GemStack::DB::QueryLogger.new(GemStack::Logger.new(@io, level: :debug, color: false), queries: queries)
  end

  def test_sql_only_when_enabled
    logger(false).debug("(0.1ms) SELECT 1")

    assert_empty @io.string
    logger(true).debug("(0.1ms) SELECT 1")

    assert_includes @io.string, "SELECT 1"
  end

  def test_probe_failures_are_not_errors
    log = logger(false)
    log.error(%(PG::UndefinedTable: ERROR:  relation "x" does not exist: SELECT NULL AS "nil" FROM "x" LIMIT 1))
    log.error(%(PG::UndefinedTable: ERROR:  relation "x" does not exist: SELECT * FROM "x" LIMIT 0))

    assert_empty @io.string
    log.error("PG::SyntaxError: boom: SELECT oops")

    assert_includes @io.string, "boom"
  end

  def test_slow_queries_always_warn
    logger(false).warn("(812ms) SELECT slow")

    assert_includes @io.string, "WARN"
  end
end

class LoadWithoutDatabaseTest < Minitest::Test
  # Requiring gemstack-db must never need a database connection.
  def test_requires_without_a_connection
    lib = ["-I#{File.expand_path("../../lib", __dir__)}"]
    ok = system(RbConfig.ruby, *lib, "-e", 'require "gemstack/db"; exit(GemStack::Model.name == "GemStack::Model" ? 0 : 1)')

    assert ok, "gemstack/db should load without a database"
  end
end
