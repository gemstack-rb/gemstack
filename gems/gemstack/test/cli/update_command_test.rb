# frozen_string_literal: true

require "test_helper"

# `gemstack update`: rubygems.org and Bundler are replaced by lambdas.
class UpdateCommandTest < Minitest::Test
  GEMFILE = <<~RUBY
    source "https://rubygems.org"

    gem "gemstack", "~> 0.3.4" # the framework
    gem "gemstack-realtime", "~> 0.3.4"
    gem "gemstack-auth", require: false
    gem "pg", "~> 1.5"
  RUBY

  def setup
    @root = Dir.mktmpdir("gemstack-update")
    @out = StringIO.new
    @bundled = []
    write("Gemfile", GEMFILE)
    lock("0.3.4")
  end

  def teardown = FileUtils.rm_rf(@root)

  def write(name, content) = File.write(File.join(@root, name), content)
  def gemfile = File.read(File.join(@root, "Gemfile"))
  def lock(version) = write("Gemfile.lock", "GEM\n  specs:\n    gemstack (#{version})\n      gemstack-cli (= #{version})\n")

  # The fake `bundle update` "installs" the version written in the Gemfile.
  def update(version: nil, latest: "0.3.5", bundle_ok: true)
    bundle = lambda do |gems|
      @bundled << gems
      lock(gemfile[/gem "gemstack", "~> ([\d.]+)"/, 1]) if bundle_ok
      bundle_ok
    end
    GemStack::CLI::UpdateGenerator.new(root: @root, version: version, output: @out,
                                       latest: -> { latest }, bundle: bundle, templates: -> { true }).run
  end

  def test_updates_every_gemstack_gem_to_the_latest_release
    assert update

    assert_includes gemfile, %(gem "gemstack", "~> 0.3.5" # the framework)
    assert_includes gemfile, %(gem "gemstack-realtime", "~> 0.3.5")
    assert_includes gemfile, %(gem "gemstack-auth", "~> 0.3.5", require: false)
    assert_includes gemfile, %(gem "pg", "~> 1.5"), "other gems are left alone"
    assert_equal [%w[gemstack gemstack-auth gemstack-realtime gemstack-cli]], @bundled
    assert_includes @out.string, "Updating GemStack 0.3.4 → 0.3.5"
    assert_includes @out.string, "GemStack 0.3.5 is installed"
  end

  def test_already_up_to_date
    lock("0.3.5")

    assert update
    assert_empty @bundled
    assert_equal GEMFILE, gemfile
    assert_includes @out.string, "already 0.3.5"
  end

  def test_never_downgrades_to_an_older_latest_release
    lock("0.3.6")

    assert update(latest: "0.3.5")
    assert_empty @bundled
    assert_includes @out.string, "newer than the latest release"
  end

  def test_an_explicit_version
    assert update(version: "0.3.4", latest: "9.9.9") # the locked version: nothing to do
    assert_empty @bundled
    assert update(version: "0.3.6")

    assert_includes gemfile, %(gem "gemstack", "~> 0.3.6")
  end

  def test_rejects_something_that_is_not_a_version
    refute update(version: "latest")
    assert_includes @out.string, "not a version"
    assert_equal GEMFILE, gemfile
  end

  def test_a_failed_bundle_update_restores_the_gemfile
    refute update(bundle_ok: false)
    assert_equal GEMFILE, gemfile
    assert_includes @out.string, "bundle update failed — the Gemfile is unchanged"
  end

  def test_an_error_while_bundling_restores_the_gemfile
    boom = ->(_gems) { raise Errno::ENOENT, "bundle" }
    updater = GemStack::CLI::UpdateGenerator.new(root: @root, output: @out, latest: -> { "0.3.5" }, bundle: boom)

    assert_raises(Errno::ENOENT) { updater.run }
    assert_equal GEMFILE, gemfile
  end

  def test_apps_on_a_gemstack_checkout
    write("Gemfile", %(path "/src/gemstack/gems" do\n  gem "gemstack"\nend\n))

    assert update
    assert_empty @bundled
    assert_includes @out.string, "git -C /src/gemstack pull"
  end

  def test_no_gemstack_in_the_gemfile
    write("Gemfile", %(gem "rack"\n))

    refute update
    assert_includes @out.string, %(no `gem "gemstack"` in the Gemfile)
  end
end
