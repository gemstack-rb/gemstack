# frozen_string_literal: true

require "rake/testtask"

# The published gems, in dependency order: gemstack-cli (only the executable)
# first, then gemstack (the framework), then the two optional modules.
GEMS = %w[gemstack-cli gemstack gemstack-auth gemstack-realtime].freeze
# The gem names merged into gemstack in 0.3.0. Their last release (0.3.0) is a
# placeholder that loads gemstack; they are never built or released again.
OLD_GEMS = %w[core cache schema http db jobs mail storage contract dev].map { |mod| "gemstack-#{mod}" }.freeze
LIBS = (GEMS - ["gemstack-cli"]).map { |gem| "gems/#{gem}/lib" }.freeze

# One test task per module (rake test:http, test:db, …) and per extra gem.
SUITES = (Dir["gems/gemstack/test/*/"].map { |dir| [File.basename(dir), dir] } +
          [["auth", "gems/gemstack-auth/test/"], ["realtime", "gems/gemstack-realtime/test/"]]).sort.freeze

namespace :test do
  SUITES.each do |name, dir|
    Rake::TestTask.new(name) do |t|
      t.libs = LIBS + [dir.chomp("/")]
      t.test_files = FileList["#{dir}**/*_test.rb"]
      t.warning = false
    end
  end
end

desc "Run every test suite"
task test: SUITES.map { |name, _| "test:#{name}" }

load File.expand_path("script/changes", __dir__) unless defined?(GemStackChanges)

desc "Run the test suites of the modules this branch changes (script/changes)"
task "test:changed" do
  suites = GemStackChanges.suites(GemStackChanges.changed_files)
  suites = SUITES.map(&:first) if suites == :all
  puts suites.empty? ? "No module changes — nothing to run." : "Running: #{suites.join(", ")}"
  suites.each { |name| Rake::Task["test:#{name}"].invoke }
end

# Setup that a new test in each suite usually needs (see each test_helper.rb).
TEST_TEMPLATES = {
  "http" => { includes: %w[Rack::Test::Methods HTTPTestHelpers] },
  "db" => { includes: %w[DBTest] },
  "auth" => { superclass: "AuthTestCase" }
}.freeze

desc 'Start a test file in a module: rake "test:new[http,rate_limiting]"'
task "test:new", [:suite, :name] do |_, args|
  dir = SUITES.to_h[args[:suite].to_s]
  name = args[:name].to_s
  abort "usage: rake \"test:new[suite,name]\" — suites: #{SUITES.map(&:first).join(", ")}" unless dir
  abort "the name is snake_case, like rate_limiting" unless name.match?(/\A[a-z][a-z0-9_]*\z/)

  file = "#{dir}#{name.delete_suffix("_test")}_test.rb"
  abort "#{file} already exists" if File.exist?(file)

  template = TEST_TEMPLATES.fetch(args[:suite], {})
  klass = "#{name.delete_suffix("_test").split("_").map(&:capitalize).join}Test"
  includes = template.fetch(:includes, []).map { |mod| "  include #{mod}\n" }.join
  File.write(file, <<~RUBY)
    # frozen_string_literal: true

    require "test_helper"

    class #{klass} < #{template.fetch(:superclass, "Minitest::Test")}
    #{includes}#{"\n" unless includes.empty?}  def test_describe_what_it_does
        flunk "write the test: arrange, act, assert (see CONTRIBUTING.md → Tests)"
      end
    end
  RUBY
  puts "Created #{file}\nRun it: bundle exec rake test:#{args[:suite]} TEST=#{file}"
end

def gem_version(name)
  Gem::Specification.load(File.expand_path("gems/#{name}/#{name}.gemspec", __dir__)).version.to_s
end

namespace :gems do
  require_relative "gems/gemstack/lib/gemstack/version"

  desc "Build every gem into pkg/"
  task :build do
    mkdir_p "pkg"
    GEMS.each do |name|
      file = "#{name}-#{gem_version(name)}.gem"
      Dir.chdir("gems/#{name}") { sh "gem build #{name}.gemspec --output ../../pkg/#{file}" }
    end
  end

  desc "Build and install the gems for the current Ruby (like `gem install gemstack`)"
  task install: :build do
    GEMS.each do |name|
      file = "#{name}-#{GemStack::VERSION}.gem"
      sh "gem install pkg/#{file} --no-document"
      # Reinstalling the same version keeps RubyGems' cached .gem, which
      # `bundle cache` (vendor/cache for Docker builds) would then copy.
      cp "pkg/#{file}", File.join(Gem.dir, "cache", file)
    end
    sh "asdf reshim ruby" if system("which asdf > /dev/null 2>&1")
  end

  desc "Uninstall every GemStack gem from the current Ruby"
  task :uninstall do
    (OLD_GEMS + GEMS.reverse).each do |name|
      sh "gem uninstall #{name} --all --executables --ignore-dependencies --force"
    end
  end

  desc "Build the gems, install them into a throwaway GEM_HOME, then run `gemstack new` from them"
  task check: :build do
    require "tmpdir"
    Dir.mktmpdir("gemstack-gems") do |home|
      env = { "GEM_HOME" => home, "GEM_PATH" => home, "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil }
      files = GEMS.map { |name| "pkg/#{name}-#{gem_version(name)}.gem" }
      Bundler.with_unbundled_env do
        sh env, "gem", "install", "--no-document", "--quiet", *files
        sh env, File.join(home, "bin", "gemstack"), "version"
        sh env, File.join(home, "bin", "gemstack"), "new", File.join(home, "check_app"), "--skip-install", "--skip-git"
      end
      puts "All #{files.size} gems build, install and generate an app."
    end
  end
end

desc "Run RuboCop"
task :lint do
  sh "bundle exec rubocop"
end

desc "Run benchmarks"
task :bench do
  Dir["benchmarks/*_bench.rb"].each { |file| ruby file }
end

# The suites that touch the database, run once per adapter:
# SQLite always; PostgreSQL with GEMSTACK_TEST_DATABASE_URL; MySQL (mysql2 and
# trilogy) with GEMSTACK_TEST_MYSQL_URL=mysql2://user:pass@127.0.0.1:3306/gemstack_test.
DATABASE_SUITES = %w[test:db test:jobs test:auth].freeze

desc "Run the database-backed suites on SQLite, PostgreSQL and MySQL (where configured)"
task "test:databases" do
  require "tmpdir"
  Dir.mktmpdir("gemstack-sqlite") do |dir|
    urls = { "sqlite3" => "sqlite3://#{dir}/gemstack_test.sqlite3" }
    if ENV["GEMSTACK_TEST_DATABASE_URL"].to_s.start_with?("postgres")
      urls["postgresql"] =
        ENV.fetch("GEMSTACK_TEST_DATABASE_URL")
    end
    if (mysql = ENV.fetch("GEMSTACK_TEST_MYSQL_URL", nil)).to_s != ""
      urls["mysql2"] = mysql.sub(/\A\w+:/, "mysql2:")
      urls["trilogy"] = mysql.sub(/\A\w+:/, "trilogy:")
    end
    urls.each do |adapter, url|
      puts "\n== #{adapter}"
      sh({ "GEMSTACK_TEST_DATABASE_URL" => url }, "bundle", "exec", "rake", *DATABASE_SUITES)
    end
    skipped = %w[postgresql mysql2] - urls.keys
    if skipped.any?
      puts "\n(not run on #{skipped.join(", ")}: set GEMSTACK_TEST_DATABASE_URL / GEMSTACK_TEST_MYSQL_URL)"
    end
  end
end

task default: %i[test test:databases lint]

desc "Set the version of gemstack, gemstack-cli, gemstack-auth and gemstack-realtime: rake version:set[0.3.1]"
task "version:set", [:version] do |_, args|
  version = args[:version].to_s
  abort "usage: rake version:set[x.y.z]" unless version.match?(/\A\d+\.\d+\.\d+(\.[0-9A-Za-z.]+)?\z/)

  files = GEMS.map { |name| "gems/#{name}/#{name}.gemspec" } + ["gems/gemstack/lib/gemstack/version.rb"]
  files.each do |file|
    content = File.read(file)
    updated = content.sub(/^(\s*(?:VERSION|version) = )"[^"]+"/, "\\1\"#{version}\"")
    File.write(file, updated) unless updated == content
  end
  puts "Set #{files.size} files to #{version}. Add a CHANGELOG.md entry, then run `bundle install` and the tests."
end
