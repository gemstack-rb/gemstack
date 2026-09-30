# frozen_string_literal: true

ENV["GEMSTACK_ENV"] = "test"
require "gemstack"
require "gemstack/testing"
require "minitest/autorun"
require "tmpdir"
require "fileutils"

# Builds a throwaway application directory and a fresh GemStack state.
module AppFixture
  def build_app(files = {}, env: "test")
    @dir = Dir.mktmpdir("gemstack-app")
    files.each do |path, content|
      full = File.join(@dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end
    GemStack.reset!
    GemStack.env = env
    GemStack.config.root = @dir
    GemStack.config.logger.output = nil
    GemStack.application
  end

  FIXTURE_CONSTANTS = %i[WidgetsController Widgets].freeze

  def teardown
    GemStack.application.loader&.unregister if GemStack.instance_variable_get(:@application)
    FIXTURE_CONSTANTS.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
    GemStack.reset!
    GemStack.env = "test"
    FileUtils.rm_rf(@dir) if @dir
  end

  def write(path, content)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    # Make mtime-based change detection deterministic within the same second.
    File.utime(Time.now + 5, Time.now + 5, full)
  end
end
