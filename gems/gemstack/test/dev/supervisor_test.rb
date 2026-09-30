# frozen_string_literal: true

require "test_helper"
require "fileutils"

# Runs the supervisor against a stand-in API process (a few lines of Ruby
# serving HTTP on GEMSTACK_API_PORT) — no Puma or Next.js required.
class SupervisorTest < Minitest::Test
  FAKE_API = <<~RUBY
    require "socket"
    server = TCPServer.new(ENV.fetch("GEMSTACK_API_HOST"), Integer(ENV.fetch("GEMSTACK_API_PORT")))
    boot = Process.pid
    $stdout.sync = true
    puts "fake api booted"
    loop do
      client = server.accept
      begin
        client.readpartial(4096)
      rescue EOFError # readiness probes connect and close without a request
        client.close
        next
      end
      body = "pid=\#{boot} env=\#{ENV["GEMSTACK_ENV"]}"
      client.write("HTTP/1.1 200 OK\\r\\ncontent-length: \#{body.bytesize}\\r\\nconnection: close\\r\\n\\r\\n\#{body}")
      client.close
    end
  RUBY

  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p("#{@root}/config")
    File.write("#{@root}/config/app.rb", "# config\n")
    File.write("#{@root}/fake_api.rb", FAKE_API)
    @io = StringIO.new
    # gemstack-http isn't loaded in this suite; the supervisor only needs api_path.
    unless GemStack::Config.namespaces.key?(:http)
      GemStack::Config.namespace(:http) { setting :api_path, default: "/api" }
    end
    config = GemStack::Config.new
    config.dev.port = 0
    config.dev.bind = ["127.0.0.1"]
    config.dev.api_command = [RbConfig.ruby, "fake_api.rb"]
    @supervisor = GemStack::Dev::Supervisor.new(root: @root, config: config, env: {},
                                                terminal: GemStack::Dev::Terminal.new(@io, color: false))
  end

  def teardown
    @supervisor.shutdown
    FileUtils.rm_rf(@root)
  end

  def wait_until(timeout = 10)
    deadline = Time.now + timeout
    until yield
      raise "timed out; output:\n#{@io.string}" if Time.now > deadline

      sleep 0.05
    end
  end

  def get(path)
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@supervisor.gateway.port}#{path}"))
  end

  def api_body
    response = get("/api/health")
    response.code == "200" ? response.body : nil
  end

  def test_serves_api_through_the_gateway_and_restarts_on_config_change
    @supervisor.start
    wait_until { api_body }
    first = api_body

    assert_match(/env=development/, first)
    assert_includes @io.string, "api     │ fake api booted"
    assert_includes @io.string, "API only"
    wait_until { @io.string.include?("Ruby API ready") }

    File.write("#{@root}/config/app.rb", "# changed\n")
    File.utime(Time.now + 5, Time.now + 5, "#{@root}/config/app.rb")
    @supervisor.send(:supervise)
    wait_until { (body = api_body) && body != first }

    assert_equal 1, @io.string.scan("restarting Ruby API").size
  end

  def test_reports_api_crash_once_and_recovers_on_file_change
    File.write("#{@root}/fake_api.rb", "exit 1")
    @supervisor.start
    wait_until { !@supervisor.processes[:api].running? }
    3.times { @supervisor.send(:supervise) }

    assert_equal 1, @io.string.scan("api exited (status 1)").size
    assert_equal "503", get("/api/health").code

    File.write("#{@root}/fake_api.rb", FAKE_API)
    File.write("#{@root}/config/app.rb", "# fixed\n")
    File.utime(Time.now + 5, Time.now + 5, "#{@root}/config/app.rb")
    @supervisor.send(:supervise)
    wait_until { api_body }
  end

  def test_shutdown_stops_children
    @supervisor.start
    wait_until { api_body }
    api = @supervisor.processes[:api]
    @supervisor.shutdown

    refute_predicate api, :running?
  end

  def test_an_old_node_stops_gemstack_dev_with_the_fix
    config = GemStack::Config.new
    supervisor = GemStack::Dev::Supervisor.new(root: @root, config: config, env: {},
                                               terminal: GemStack::Dev::Terminal.new(@io, color: false))
    File.write("#{@root}/.nvmrc", "22.11.0\n")
    error = assert_raises(GemStack::Error) do
      supervisor.send(:check_node!, { version: "18.20.1", path: "/Users/me/.nvm/versions/node/v18.20.1/bin/node" })
    end

    assert_includes error.message, "found Node.js 18.20.1"
    assert_includes error.message, "nvm install 22.11.0 && nvm use 22.11.0"
    assert_nil supervisor.send(:check_node!, { version: "22.11.0", path: "/usr/bin/node" })
    assert_includes assert_raises(GemStack::Error) { supervisor.send(:check_node!, nil) }.message, "no `node` on the PATH"
  end

  def test_job_worker_runs_only_with_the_postgres_queue_and_its_migration
    require "gemstack/jobs"
    config = GemStack::Config.new
    config.dev.port = 0
    config.dev.bind = ["127.0.0.1"]
    config.dev.api_command = [RbConfig.ruby, "fake_api.rb"]
    config.dev.jobs_command = [RbConfig.ruby, "-e", "$stdout.sync = true; puts 'fake worker'; sleep"]
    config.jobs.adapter = :postgres
    supervisor = GemStack::Dev::Supervisor.new(root: @root, config: config, env: {},
                                               terminal: GemStack::Dev::Terminal.new(@io, color: false))
    supervisor.start

    refute supervisor.processes.key?(:jobs), "no gemstack_jobs migration yet"

    FileUtils.mkdir_p("#{@root}/db/migrations")
    File.write("#{@root}/db/migrations/20260101000000_create_gemstack_jobs.rb", "# jobs")
    supervisor.send(:supervise)
    wait_until { @io.string.include?("fake worker") }

    assert_predicate supervisor.processes[:jobs], :running?
    config.jobs.adapter = :async

    refute supervisor.send(:jobs_enabled?)
  ensure
    supervisor&.shutdown
  end
end
