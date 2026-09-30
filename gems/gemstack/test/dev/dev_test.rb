# frozen_string_literal: true

require "test_helper"

class FileWatcherTest < Minitest::Test
  def test_detects_edits_additions_and_deletions
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/app/controllers")
      File.write("#{dir}/app/controllers/a.rb", "1")
      watcher = GemStack::Dev::FileWatcher.new(["app/**/*"], root: dir)

      refute_predicate watcher, :changed?

      File.write("#{dir}/app/controllers/a.rb", "22")

      assert_predicate watcher, :changed?
      refute_predicate watcher, :changed?

      File.write("#{dir}/app/controllers/b.rb", "1")

      assert_predicate watcher, :changed?

      File.delete("#{dir}/app/controllers/a.rb")

      assert_predicate watcher, :changed?
    end
  end

  def test_rewrites_with_identical_content_are_not_changes
    Dir.mktmpdir do |dir|
      File.write("#{dir}/Gemfile.lock", "GEM\n")
      watcher = GemStack::Dev::FileWatcher.new(["Gemfile.lock"], root: dir)
      File.write("#{dir}/Gemfile.lock", "GEM\n")
      File.utime(Time.now + 10, Time.now + 10, "#{dir}/Gemfile.lock") # e.g. Bundler 4 on `bundle exec`

      refute_predicate watcher, :changed?

      File.write("#{dir}/Gemfile.lock", "GEM\n  rack\n")

      assert_predicate watcher, :changed?
    end
  end

  def test_excludes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/config")
      watcher = GemStack::Dev::FileWatcher.new(["config/**/*.rb"], root: dir, exclude: ["config/routes.rb"])
      File.write("#{dir}/config/routes.rb", "x")

      refute_predicate watcher, :changed?
      File.write("#{dir}/config/app.rb", "x")

      assert_predicate watcher, :changed?
    end
  end
end

class ManagedProcessTest < Minitest::Test
  def setup
    @io = StringIO.new
    @terminal = GemStack::Dev::Terminal.new(@io, color: false)
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now > deadline
  end

  def test_streams_prefixed_output_and_records_status
    process = GemStack::Dev::ManagedProcess.new("api", [RbConfig.ruby, "-e", "puts 'hello'; warn 'oops'; exit 3"],
                                                terminal: @terminal).start
    wait_for { !process.running? }
    wait_for { @io.string.include?("oops") }

    assert_includes @io.string, "api     │ hello"
    assert_includes @io.string, "api     │ oops"
    assert_equal 3, process.status.exitstatus
    assert_equal "status 3", process.describe_status
  end

  def test_env_and_chdir
    Dir.mktmpdir do |dir|
      process = GemStack::Dev::ManagedProcess.new("x", [RbConfig.ruby, "-e", "puts ENV['FOO'], Dir.pwd"],
                                                  terminal: @terminal, env: { "FOO" => "bar" }, chdir: dir).start
      wait_for { !process.running? }
      wait_for { @io.string.lines.size >= 2 }

      assert_includes @io.string, "bar"
      assert_includes @io.string, File.basename(dir)
    end
  end

  def test_stop_terminates_process_group
    script = "$stdout.sync = true; puts 'ready'; sleep 30"
    process = GemStack::Dev::ManagedProcess.new("x", [RbConfig.ruby, "-e", script], terminal: @terminal).start
    # A TERM that lands while Ruby is still booting can end it with status 1
    # instead of the signal; stop it once it runs the script.
    wait_for { @io.string.include?("ready") }

    assert_predicate process, :running?
    process.stop(timeout: 2)

    refute_predicate process, :running?
    assert_predicate process.status, :signaled?
  end

  def test_missing_command
    process = GemStack::Dev::ManagedProcess.new("x", ["definitely-not-a-command-gemstack"], terminal: @terminal).start

    refute_predicate process, :running?
    assert_includes @io.string, "could not start"
  end
end

class PortsTest < Minitest::Test
  def test_free_and_open
    port = GemStack::Dev::Ports.free

    refute GemStack::Dev::Ports.open?("127.0.0.1", port)
    server = TCPServer.new("127.0.0.1", port)

    assert GemStack::Dev::Ports.open?("127.0.0.1", port)
  ensure
    server&.close
  end
end

class DevConfigTest < Minitest::Test
  def test_defaults
    config = GemStack::Config.new

    assert_equal 3000, config.dev.port unless ENV["PORT"]
    assert_equal "frontend", config.dev.frontend_dir
    assert_includes config.dev.restart_exclude, "config/routes.rb"
  end
end
