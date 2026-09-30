# frozen_string_literal: true

require "test_helper"
require "gemstack"

class ConsoleTest < Minitest::Test
  def test_reload_delegates_to_application
    application = Object.new
    calls = 0

    application.define_singleton_method(:reload!) do
      calls += 1
      true
    end

    console = Object.new
    console.extend(GemStack::CLI::ConsoleMethods)

    GemStack.stub(:application, application) do
      assert_equal true, console.reload!
    end

    assert_equal 1, calls
  end
end
