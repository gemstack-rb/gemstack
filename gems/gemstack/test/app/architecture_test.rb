# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# Enforces the module boundaries described in ARCHITECTURE.md §2. Since 0.3.0
# most modules live in the gemstack gem; the boundaries are checked on the
# require graph instead of gemspecs.
class ArchitectureTest < Minitest::Test
  GEMS_DIR = File.expand_path("../../..", __dir__)
  GEMS = %w[gemstack-cli gemstack gemstack-auth gemstack-realtime].freeze

  # A module may only require modules before it in this list ("app" is the
  # umbrella: GemStack::Application, reloading, test helpers).
  ORDER = %w[core cache schema http db jobs mail storage realtime auth contract dev cli app].freeze
  # Loose files that belong to a module.
  FILES = {
    "core" => %w[core settings environment logger errors error_mapping inflector plugins dotenv version],
    "schema" => %w[schema serializer types], "jobs" => %w[jobs job],
    "app" => %w[application interlock reloader testing], "auth" => %w[auth policy]
  }.freeze

  def spec(name) = Gem::Specification.load(File.join(GEMS_DIR, name, "#{name}.gemspec"))

  def module_of(lib, file)
    rel = file.delete_prefix("#{lib}/")
    return "app" if rel == "gemstack.rb"

    first = rel.delete_prefix("gemstack/").split("/").first.delete_suffix(".rb")
    FILES.find { |_, names| names.include?(first) }&.first || first
  end

  # { "gemstack/lib/gemstack/db.rb" => ["core", "schema"], … } — the GemStack
  # modules each file requires (comments ignored).
  def requires_by_file
    @requires_by_file ||= GEMS.flat_map do |gem|
      lib = File.join(GEMS_DIR, gem, "lib")
      Dir["#{lib}/**/*.rb"].map do |file|
        code = File.readlines(file).grep_v(/\A\s*#/).join
        targets = code.scan(%r{^\s*require(?:_relative)?\s+["']gemstack/([a-z_]+)}).flatten.map do |name|
          FILES.find { |_, names| names.include?(name) }&.first || name
        end
        [[module_of(lib, file), file.delete_prefix("#{GEMS_DIR}/")], targets.uniq]
      end
    end.to_h
  end

  def test_modules_only_depend_on_earlier_modules
    requires_by_file.each do |(mod, file), targets|
      targets.each do |target|
        next if target == mod

        assert ORDER.include?(target), "#{file} requires unknown module gemstack/#{target}"
        assert_operator ORDER.index(target), :<, ORDER.index(mod), "#{file} (#{mod}) → #{target} points up the graph"
      end
    end
  end

  def test_core_uses_only_the_standard_library
    offenders = requires_by_file.select { |(mod, _), targets| mod == "core" && (targets - ["core"]).any? }

    assert_empty offenders.keys.map(&:last)
  end

  def test_database_is_optional_and_independent_of_http
    db = requires_by_file.select { |(mod, _), _| mod == "db" }.values.flatten

    refute_includes db, "http", "the DB layer must not depend on HTTP"
    umbrella = requires_by_file.fetch(["app", "gemstack/lib/gemstack.rb"])

    assert_empty umbrella & %w[db jobs mail storage], "require \"gemstack\" must not load opt-in modules"
  end

  def test_core_loads_alone
    lib = File.join(GEMS_DIR, "gemstack/lib")
    script = 'require "gemstack/core"; print [defined?(GemStack::HTTP), defined?(Rack), defined?(Thor)].compact.size'
    out, status = Open3.capture2e(RbConfig.ruby, "--disable-gems", "-I", lib, "-e", script)

    assert_predicate status, :success?, out
    assert_equal "0", out
  end

  def test_dev_tooling_is_not_loaded_by_default
    %w[Gateway Supervisor ManagedProcess].each do |name|
      assert_equal "gemstack/dev/#{Inflector.underscore(name)}", GemStack::Dev.autoload?(name.to_sym)
    end
  end

  def test_publishable_metadata
    GEMS.map { |name| [name, spec(name)] }.each do |name, s|
      assert_equal ["Adware Technologies", "Shoaib Malik"], s.authors
      assert_equal "MIT", s.license
      assert_equal "true", s.metadata["rubygems_mfa_required"]
      %w[source_code_uri changelog_uri bug_tracker_uri documentation_uri].each do |key|
        assert s.metadata[key]&.start_with?("https://github.com/gemstack-rb/gemstack"), "#{name}: #{key}"
      end
      %w[README.md LICENSE.txt CHANGELOG.md].each { |file| assert_includes s.files, file, "#{name} ships #{file}" }
    end
    GEMS.each do |name|
      %w[README.md LICENSE.txt CHANGELOG.md].each do |file|
        assert File.file?(File.join(GEMS_DIR, name, file)), "#{name} is missing #{file}"
      end
    end
  end

  def test_gems_share_one_version_and_pin_each_other
    GEMS.each do |name|
      s = spec(name)

      assert_equal GemStack::VERSION, s.version.to_s, "#{name}: rake version:set keeps the gems on one version"
      deps = s.runtime_dependencies.select { |d| d.name.start_with?("gemstack") }
      expected = { "gemstack-cli" => [], "gemstack" => [["gemstack-cli", "= #{GemStack::VERSION}"]] }
                 .fetch(name, [["gemstack", "= #{GemStack::VERSION}"]])

      assert_equal expected, deps.map { |d| [d.name, d.requirement.to_s] }, name
    end
  end

  # The names merged into gemstack in 0.3.0 had their last release then; only
  # these four gems are built and released.
  def test_only_the_four_gems_are_released
    assert_equal GEMS.sort, Dir["#{GEMS_DIR}/*/*.gemspec"].map { |file| File.basename(file, ".gemspec") }.sort
    out, status = Open3.capture2e(File.expand_path("../../../../script/gems", __dir__))

    assert_predicate status, :success?, out
    assert_equal GEMS.map { |name| "#{name} #{GemStack::VERSION}" }, out.lines(chomp: true)
  end

  # gemstack-cli owns the executable (it did before 0.3.0, and RubyGems won't
  # hand an installed executable to another gem); the code is in gemstack.
  def test_the_executable_belongs_to_gemstack_cli
    assert_equal %w[gemstack gsk], spec("gemstack-cli").executables
    assert_empty spec("gemstack").executables
    assert_empty spec("gemstack-cli").runtime_dependencies, "no cycle: gemstack depends on gemstack-cli"
    assert File.file?(File.join(GEMS_DIR, "gemstack/lib/gemstack/cli.rb"))
  end

  Inflector = GemStack::Inflector
end
