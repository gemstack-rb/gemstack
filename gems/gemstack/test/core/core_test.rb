# frozen_string_literal: true

require "test_helper"

class EnvironmentTest < Minitest::Test
  def test_detects_from_gemstack_env_then_rack_env
    assert_equal "staging", GemStack::Environment.detect({ "GEMSTACK_ENV" => "staging", "RACK_ENV" => "x" }).name
    assert_equal "production", GemStack::Environment.detect({ "RACK_ENV" => "production" }).name
    assert_equal "development", GemStack::Environment.detect({}).name
  end

  def test_predicates
    env = GemStack::Environment.new("Production")

    assert_predicate env, :production?
    refute_predicate env, :local?
    assert_equal env, "production"
  end

  def test_rejects_empty
    assert_raises(ArgumentError) { GemStack::Environment.new(" ") }
  end
end

class DotenvTest < Minitest::Test
  def test_parse
    vars = GemStack::Dotenv.parse(<<~ENV)
      # comment
      PLAIN=value
      export EXPORTED=yes
      SPACED = trimmed # trailing comment
      DOUBLE="line\\nbreak \\"quoted\\""
      SINGLE='literal \\n $HOME'
      HASH_IN_QUOTES="a # b"
      EMPTY=
      not a line
    ENV

    assert_equal "value", vars["PLAIN"]
    assert_equal "yes", vars["EXPORTED"]
    assert_equal "trimmed", vars["SPACED"]
    assert_equal "line\nbreak \"quoted\"", vars["DOUBLE"]
    assert_equal "literal \\n $HOME", vars["SINGLE"]
    assert_equal "a # b", vars["HASH_IN_QUOTES"]
    assert_equal "", vars["EMPTY"]
    assert_equal 7, vars.size
  end

  def test_load_never_overrides_existing_and_first_file_wins
    Dir.mktmpdir do |dir|
      File.write("#{dir}/.env.local", "A=local\n")
      File.write("#{dir}/.env", "A=base\nB=base\nC=base\n")
      env = { "C" => "real" }
      loaded = GemStack::Dotenv.load("#{dir}/.env.local", "#{dir}/.env", "#{dir}/missing", env: env)

      assert_equal({ "A" => "local", "B" => "base" }, loaded)
      assert_equal "real", env["C"]
    end
  end
end

class ErrorsTest < Minitest::Test
  def test_defaults_per_class
    error = GemStack::NotFound.new

    assert_equal 404, error.status
    assert_equal "not_found", error.code
    assert_equal "Not Found", error.message
    assert_predicate error, :expose_message?
  end

  def test_overrides
    error = GemStack::NotFound.new("Product 3 not found", code: "product_not_found")

    assert_equal "product_not_found", error.code
    assert_equal "Product 3 not found", error.message
  end

  def test_validation_error_details
    error = GemStack::ValidationError.new(errors: { name: ["is required"] })

    assert_equal 422, error.status
    assert_equal({ name: ["is required"] }, error.errors)
  end

  def test_server_errors_hide_messages
    refute_predicate GemStack::Error.new("db password wrong"), :expose_message?
  end

  def test_subclass_inherits_status
    klass = Class.new(GemStack::Forbidden)

    assert_equal 403, klass.new.status
  end
end

class PluginsTest < Minitest::Test
  def teardown
    GemStack::Plugins.unregister(:sample)
  end

  def test_register_and_run
    calls = []
    GemStack::Plugins.register(:sample) { |app| calls << app }
    GemStack::Plugins.run(:app)

    assert_equal [:app], calls
    assert GemStack::Plugins.registered?(:sample)
  end

  def test_requires_block
    assert_raises(ArgumentError) { GemStack::Plugins.register(:sample) }
  end
end

class GemStackModuleTest < Minitest::Test
  def teardown
    GemStack.reset!
  end

  def test_configure_yields_config
    GemStack.configure { |c| c.name = "shop" }

    assert_equal "shop", GemStack.config.name
  end

  def test_name_defaults_to_root_basename
    GemStack.config.root = "/tmp/my_shop"

    assert_equal "my_shop", GemStack.config.name
  end

  def test_env_files_only_in_local_environments
    GemStack.env = "production"

    assert_empty GemStack.config.env_files
  end

  def test_test_logger_discards_by_default
    refute_predicate GemStack.logger, :info?
  end
end

class SetupTest < Minitest::Test
  def teardown
    GemStack.reset!
    ENV.delete("GEMSTACK_SETUP_PROBE")
  end

  def test_setup_sets_root_and_loads_env_files_once
    Dir.mktmpdir do |dir|
      File.write("#{dir}/.env", "GEMSTACK_SETUP_PROBE=from_file\n")
      GemStack.setup(root: dir)

      assert_equal dir, GemStack.config.root
      assert_equal "from_file", ENV.fetch("GEMSTACK_SETUP_PROBE")
      ENV["GEMSTACK_SETUP_PROBE"] = "changed"
      GemStack.load_env_files!

      assert_equal "changed", ENV.fetch("GEMSTACK_SETUP_PROBE")
    end
  end
end

class SecretTest < Minitest::Test
  def teardown
    GemStack.reset!
    ENV.delete("SECRET_KEY_BASE")
  end

  def test_local_secret_is_generated_once_and_kept_private
    Dir.mktmpdir do |dir|
      GemStack.config.root = dir
      first = GemStack.config.secret_key_base
      GemStack.reset!
      GemStack.config.root = dir

      assert_equal 128, first.size
      assert_equal first, GemStack.config.secret_key_base
      assert_equal "600", format("%o", File.stat("#{dir}/tmp/test_secret").mode & 0o777)
    end
  end

  def test_production_requires_secret_key_base
    GemStack.env = "production"

    assert_raises(GemStack::ConfigurationError) { GemStack.key_for("storage") }
    ENV["SECRET_KEY_BASE"] = "x" * 64
    GemStack.reset!
    GemStack.env = "production"

    assert_equal 32, GemStack.key_for("storage").bytesize
    refute_equal GemStack.key_for("storage"), GemStack.key_for("other")
  end
end
