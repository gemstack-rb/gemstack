# frozen_string_literal: true

require "test_helper"
require "rack/mock"

class DocsTest < Minitest::Test
  FakeApp = Struct.new(:routes, :config)

  def application
    router = GemStack::HTTP::Router.new(prefix: "/api").draw do
      resources :ct_widgets, path: "/widgets", only: %i[index create]
    end
    config = GemStack::Config.new
    FakeApp.new(router.routes, config)
  end

  def docs = GemStack::Contract::Docs.new(->(_) { [404, {}, ["next"]] }, application)

  def get(path) = docs.call(Rack::MockRequest.env_for(path))

  def test_page_is_self_contained
    status, headers, body = get("/api/docs")
    html = body.join

    assert_equal 200, status
    assert_includes html, %(const OPENAPI_URL = "/api/docs/openapi.json")
    refute_match(%r{<script[^>]+src=|<link[^>]+href="https?://}, html, "no external assets")
    assert_includes headers["content-security-policy"], "connect-src 'self'"
  end

  def test_openapi_is_built_from_the_current_routes
    status, headers, body = get("/api/docs/openapi.json")
    document = JSON.parse(body.join)

    assert_equal 200, status
    assert_equal "no-store", headers["cache-control"]
    assert_equal %w[get post], document["paths"]["/api/widgets"].keys.sort
    assert_kind_of Array, document["x-gemstack-warnings"]
  end

  def test_other_paths_pass_through
    assert_equal 404, get("/api/widgets").first
    assert_equal 404, docs.call(Rack::MockRequest.env_for("/api/docs", method: "POST")).first
  end

  def test_enabled_in_development_only
    config = GemStack::Contract::Config.new
    { "development" => true, "test" => false, "production" => false }.each do |env, expected|
      GemStack.stub(:env, GemStack::Environment.new(env)) { assert_equal expected, config.docs, env }
      config = GemStack::Contract::Config.new
    end
  end
end
