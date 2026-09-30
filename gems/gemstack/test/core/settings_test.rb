# frozen_string_literal: true

require "test_helper"

class SettingsTest < Minitest::Test
  class Sample < GemStack::Settings
    setting :port, default: 3000
    setting :tags, default: []
    setting :url, default: -> { "http://localhost:#{port}" }
    namespace :cors do
      setting :origins, default: []
    end
  end

  def test_static_default
    assert_equal 3000, Sample.new.port
  end

  def test_assignment_overrides_default
    config = Sample.new
    config.port = 4000

    assert_equal 4000, config.port
    assert config.set?(:port)
  end

  def test_lazy_default_sees_other_settings
    config = Sample.new
    config.port = 9000

    assert_equal "http://localhost:9000", config.url
  end

  def test_mutable_defaults_are_not_shared
    one = Sample.new
    two = Sample.new
    one.tags << "x"

    assert_empty two.tags
  end

  def test_namespaces_are_memoized_and_accept_blocks
    config = Sample.new
    config.cors { |cors| cors.origins = ["https://example.com"] }

    assert_equal ["https://example.com"], config.cors.origins
    assert_same config.cors, config.cors
  end

  def test_unknown_settings_raise
    assert_raises(NoMethodError) { Sample.new.prot = 1 }
  end

  def test_to_h_includes_namespaces
    assert_equal({ port: 3000, tags: [], url: "http://localhost:3000", cors: { origins: [] } }, Sample.new.to_h)
  end

  def test_subclasses_inherit_and_extend
    subclass = Class.new(Sample) { setting :extra, default: 1 }

    assert_equal 3000, subclass.new.port
    assert_equal 1, subclass.new.extra
    refute_respond_to Sample.new, :extra
  end

  def test_registering_a_namespace_on_config
    GemStack::Config.namespace(:sample_module) { setting :enabled, default: true }

    assert GemStack::Config.new.sample_module.enabled
  end
end
