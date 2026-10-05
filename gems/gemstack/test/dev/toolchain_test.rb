# frozen_string_literal: true

require "test_helper"

class ToolchainTest < Minitest::Test
  T = GemStack::Dev::Toolchain

  Status = Struct.new(:ok) do
    def success? = ok
  end

  def test_detects_ruby_managers_from_the_executable_path
    {
      "/Users/me/.rbenv/versions/3.3.6/bin/ruby" => :rbenv,
      "/Users/me/.rvm/rubies/ruby-3.3.6/bin/ruby" => :rvm,
      "/Users/me/.asdf/installs/ruby/3.4.1/bin/ruby" => :asdf,
      "/Users/me/.local/share/mise/installs/ruby/3.4.1/bin/ruby" => :mise,
      "/Users/me/.rubies/ruby-3.4.1/bin/ruby" => :chruby,
      "/opt/homebrew/opt/ruby/bin/ruby" => :homebrew,
      "/usr/bin/ruby" => nil
    }.each { |path, manager| manager.nil? ? assert_nil(T.ruby_manager(path), path) : assert_equal(manager, T.ruby_manager(path), path) }
  end

  def test_detects_node_managers
    {
      "/Users/me/.nvm/versions/node/v22.11.0/bin/node" => :nvm,
      "/Users/me/.local/state/fnm_multishells/123/bin/node" => :fnm,
      "/Users/me/.nodenv/versions/22.11.0/bin/node" => :nodenv,
      "/Users/me/.asdf/installs/nodejs/22.11.0/bin/node" => :asdf,
      "/Users/me/.volta/tools/image/node/22.11.0/bin/node" => :volta,
      "/usr/bin/node" => nil
    }.each { |path, manager| manager.nil? ? assert_nil(T.node_manager(path), path) : assert_equal(manager, T.node_manager(path), path) }
  end

  def test_hints_use_the_manager_or_stay_generic
    assert_equal "rbenv install 3.3.6 && rbenv local 3.3.6", T.ruby_hint("3.3.6", :rbenv)
    assert_equal "rvm install 3.3.6 && rvm use 3.3.6", T.ruby_hint("3.3.6", :rvm)
    assert_includes T.ruby_hint("3.4.1", nil), "rbenv, rvm, asdf or mise"
    assert_equal "volta install node@22", T.node_hint("22", :volta)
    assert_includes T.node_hint("22", nil), "nvm, fnm, asdf or mise"
  end

  def test_versions
    assert T.node_ok?("20.9.0")
    refute T.node_ok?("20.8.1")
    refute T.node_ok?("18.20.1")
    assert T.ruby_ok?("3.3.0")
    refute T.ruby_ok?("3.2.9")
  end

  def test_node_probe_and_pin
    run = ->(*) { ["v22.11.0 /x/bin/node\n", Status.new(true)] }

    assert_equal({ version: "22.11.0", path: "/x/bin/node" }, T.node(run))
    assert_equal "22.11.0", T.pinned_node_version(run)
    old = ->(*) { ["v18.20.1 /x/bin/node\n", Status.new(true)] }

    assert_equal "22", T.pinned_node_version(old), "too old to pin: the LTS line instead"
    assert_nil T.node(->(*) { raise Errno::ENOENT })
  end
end
