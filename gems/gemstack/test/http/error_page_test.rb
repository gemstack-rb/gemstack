# frozen_string_literal: true

require "test_helper"

class ErrorPageTest < Minitest::Test
  include HTTPTestHelpers

  M = GemStack::HTTP::Middleware

  def boom(_env)
    raise ArgumentError, "bad <input> & more" # the line shown on the page
  end

  def handler(show: true)
    config = build_config
    config.show_exceptions = show
    M::ErrorHandler.new(method(:boom), config)
  end

  def setup
    GemStack.config.logger.output = nil
    @root = GemStack.config.root
    GemStack.config.root = File.expand_path("../..", __dir__)
  end

  def teardown = GemStack.config.root = @root

  def test_browsers_get_an_html_page_in_development
    status, headers, body = handler.call(env_for("/api/boom", "HTTP_SEC_FETCH_DEST" => "document"))
    html = body.join

    assert_equal 500, status
    assert_equal "text/html; charset=utf-8", headers["content-type"]
    assert_includes html, "<h1>ArgumentError</h1>"
    assert_includes html, "bad &lt;input&gt; &amp; more", "escaped"
    assert_includes html, "test/http/error_page_test.rb"
    assert_match(%r{class="hit"><i>\d+</i>    raise ArgumentError}, html, "the failing line is highlighted")
    assert_includes html, %(<li class="app">test/http/error_page_test.rb:)
  end

  def test_gem_frames_are_shortened
    frames = GemStack::HTTP::ErrorPage.frames(Struct.new(:backtrace).new(["#{Gem.path.first}/gems/rack-3.2.4/lib/rack.rb:1:in 'x'"]))

    assert_equal "rack-3.2.4/lib/rack.rb:1:in 'x'", frames.first[:display]
  end

  def test_fetch_and_api_clients_keep_json
    _, headers, = handler.call(env_for("/api/boom", "HTTP_SEC_FETCH_DEST" => "empty", "HTTP_ACCEPT" => "text/html"))

    assert_equal "application/json; charset=utf-8", headers["content-type"]
    _, headers, = handler.call(env_for("/api/boom", "HTTP_ACCEPT" => "application/json"))

    assert_equal "application/json; charset=utf-8", headers["content-type"]
  end

  def test_old_browsers_without_fetch_metadata
    _, headers, = handler.call(env_for("/api/boom", "HTTP_ACCEPT" => "text/html,application/xhtml+xml"))

    assert_equal "text/html; charset=utf-8", headers["content-type"]
  end

  def test_never_in_production
    _, headers, body = handler(show: false).call(env_for("/api/boom", "HTTP_SEC_FETCH_DEST" => "document"))

    assert_equal "application/json; charset=utf-8", headers["content-type"]
    refute_includes body.join, "bad"
  end

  def test_client_errors_stay_json
    config = build_config
    app = M::ErrorHandler.new(->(_) { raise GemStack::NotFound }, config)
    status, headers, = app.call(env_for("/api/x", "HTTP_SEC_FETCH_DEST" => "document"))

    assert_equal [404, "application/json; charset=utf-8"], [status, headers["content-type"]]
  end
end
