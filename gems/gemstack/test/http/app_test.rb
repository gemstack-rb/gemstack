# frozen_string_literal: true

require "test_helper"

# The full default stack in front of a router, as an application sees it.
class AppTest < Minitest::Test
  include Rack::Test::Methods
  include HTTPTestHelpers

  class PingController < GemStack::HTTP::Controller
    def show = render({ pong: true })
  end

  def app
    @app ||= begin
      config = build_config
      router = GemStack::HTTP::Router.new(prefix: config.api_path, resolver: ->(_) { PingController })
      router.draw { get "/ping", to: "ping#show" }
      GemStack::HTTP::App.new(config: config, router: router)
    end
  end

  def test_success_path
    get "/api/ping"

    assert_equal 200, last_response.status
    assert_equal({ "pong" => true }, json(last_response))
    assert last_response.headers["x-request-id"]
    assert_equal "nosniff", last_response.headers["x-content-type-options"]
  end

  def test_unknown_route_is_json_404
    get "/api/missing"

    assert_equal 404, last_response.status
    assert_equal "route_not_found", json(last_response)["error"]["code"]
    assert_equal last_response.headers["x-request-id"], json(last_response)["error"]["request_id"]
  end

  def test_wrong_method_is_405_with_allow
    delete "/api/ping"

    assert_equal 405, last_response.status
    assert_equal "GET, HEAD", last_response.headers["allow"]
  end

  def test_head
    head "/api/ping"

    assert_equal 200, last_response.status
    assert_empty last_response.body
  end

  def test_health_check
    get "/api/health"

    assert_equal({ "status" => "ok" }, json(last_response))
  end

  def test_payload_too_large
    app.config.max_body_size # already built with 10MB; build a small one
    config = build_config
    config.max_body_size = 5
    small = GemStack::HTTP::App.new(config: config, router: GemStack::HTTP::Router.new)
    status, _, body = small.call(env_for("/api/ping", method: "POST", input: "123456"))

    assert_equal 413, status
    assert_equal "payload_too_large", json([status, {}, body])["error"]["code"]
  end

  def test_rack_lint_compliance
    linted = Rack::Lint.new(app)
    status, _, body = linted.call(env_for("/api/ping"))
    body.each { |_| next }
    body.close

    assert_equal 200, status
  end
end
