# frozen_string_literal: true

require "test_helper"

class DoctorTest < Minitest::Test
  Status = Struct.new(:ok) do
    def success? = ok
  end

  def setup
    @root = Dir.mktmpdir
    @out = StringIO.new
    @commands = {}
  end

  def teardown = FileUtils.rm_rf(@root)

  def doctor(**)
    run = lambda do |*command|
      out = @commands.fetch(command.first) { return ["", Status.new(false)] }
      [out.respond_to?(:call) ? out.call(command) : out, Status.new(true)]
    end
    GemStack::CLI::Doctor.new(root: @root, output: @out, color: false, run: run, **)
  end

  def statuses(doc) = doc.results.map { |r| [r.status, r.title] }

  def test_ruby_version_pin
    File.write("#{@root}/.ruby-version", "3.3.0\n")
    doc = doctor.tap(&:check_ruby)

    assert_equal :warn, doc.results.first.status
    assert_includes @out.string, GemStack::Dev::Toolchain.ruby_hint("3.3.0")
    File.write("#{@root}/.ruby-version", "#{RUBY_VERSION}\n")

    assert_equal :ok, doctor.tap(&:check_ruby).results.first.status
  end

  def test_node_versions
    FileUtils.mkdir_p("#{@root}/frontend")
    @commands["node"] = "v18.19.0 /Users/me/.nvm/versions/node/v18.19.0/bin/node\n"
    doc = doctor.tap(&:check_node)

    assert_equal [[:fail, "Node.js 18.19.0 (/Users/me/.nvm/versions/node/v18.19.0/bin/node)"]], statuses(doc)
    assert_includes @out.string, "nvm install 22 && nvm use 22", "the hint uses the manager that installed node"
    File.write("#{@root}/.node-version", "22.11.0\n")
    @commands["node"] = "v18.19.0 /Users/me/.local/share/fnm/node-versions/v18/installation/bin/node\n"
    doctor.tap(&:check_node)

    assert_includes @out.string, "fnm install 22.11.0 && fnm use 22.11.0", "and the version the app pins"
    @commands["node"] = "v22.11.0 /usr/local/bin/node\n"

    assert_equal [[:ok, "Node.js 22.11.0"]], statuses(doctor.tap(&:check_node))
    @commands.delete("node")

    assert_equal [[:fail, "Node.js not found"]], statuses(doctor.tap(&:check_node))
  end

  def test_no_frontend_no_node_checks
    doc = doctor.tap(&:check_node).tap(&:check_frontend_dependencies)

    assert_empty doc.results
  end

  def test_frontend_dependencies
    FileUtils.mkdir_p("#{@root}/frontend/node_modules")

    assert_equal :fail, doctor.tap(&:check_frontend_dependencies).results.first.status
    File.write("#{@root}/frontend/node_modules/.package-lock.json", "{}")
    File.write("#{@root}/frontend/package-lock.json", "{}")
    File.utime(Time.now - 60, Time.now - 60, "#{@root}/frontend/package-lock.json")

    assert_equal :ok, doctor.tap(&:check_frontend_dependencies).results.first.status
    File.utime(Time.now + 60, Time.now + 60, "#{@root}/frontend/package-lock.json")

    assert_equal :warn, doctor.tap(&:check_frontend_dependencies).results.first.status
  end

  def test_secrets_tracked_by_git
    FileUtils.mkdir_p("#{@root}/.git")
    @commands["git"] = ".env\n.env.example\n"
    doc = doctor.tap(&:check_git_secrets)

    assert_equal [[:fail, "secret files tracked by git: .env"]], statuses(doc)
    assert_includes @out.string, "rotate every secret"
    @commands["git"] = ".env.example\n"

    assert_equal :ok, doctor.tap(&:check_git_secrets).results.first.status
  end

  def test_port_in_use
    server = TCPServer.new("127.0.0.1", 0)
    ENV["PORT"] = server.addr[1].to_s

    assert_equal :warn, doctor.tap(&:check_port).results.first.status
    assert_includes @out.string, "PORT=#{server.addr[1] + 1} gemstack dev"
  ensure
    server&.close
    ENV.delete("PORT")
  end

  def test_apps_from_before_0_3_get_upgrade_steps
    FileUtils.mkdir_p(%W[#{@root}/bin #{@root}/config])
    File.write("#{@root}/Gemfile", %(gem "gemstack", "~> 0.3.0"\ngem "gemstack-db", "~> 0.2.5"\ngem "gemstack-mail"\n))
    File.write("#{@root}/config/app.rb", %(require "gemstack"\nrequire "gemstack/mail"\n))
    doc = doctor.tap(&:check_gemstack_upgrade)

    assert_equal :warn, doc.results.first.status
    assert_includes @out.string, %(remove gem "gemstack-db", gem "gemstack-mail" from the Gemfile)
    assert_includes @out.string, %(add require "gemstack/db" to config/app.rb)
    refute_includes @out.string, %(require "gemstack/mail" to), "already required"
  end

  def test_current_apps_need_no_upgrade
    File.write("#{@root}/Gemfile", %(gem "gemstack", "~> 0.3.0"\ngem "gemstack-auth"\n))

    assert_empty doctor.tap(&:check_gemstack_upgrade).results
  end

  def test_output_and_ok
    FileUtils.mkdir_p("#{@root}/frontend")
    doc = doctor.tap(&:check_node)

    refute doc.ok?
    assert_match(/✗ Node.js not found\n      → install Node.js/, @out.string)
  end
end
