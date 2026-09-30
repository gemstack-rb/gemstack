# frozen_string_literal: true

require "test_helper"

class ControllerTest < Minitest::Test
  include Rack::Test::Methods
  include HTTPTestHelpers

  class PaymentDeclined < StandardError; end
  class Teapot < StandardError; end

  class BaseController < GemStack::HTTP::Controller
    rescue_from(PaymentDeclined) { |e| render({ declined: e.message }, status: 402) }

    def helper_visible_as_action = render({ ok: true })
  end

  class ItemsController < BaseController
    before :load_item, only: %w[show]
    before(only: "secret") { head :unauthorized unless request.get_header("HTTP_AUTHORIZATION") }
    after { headers["x-after"] = "1" }
    rescue_from Teapot, status: 504

    def index = render([{ id: 1 }, { id: 2 }])
    def show = render(@item)
    def create = render(params.require(:item).permit(:name), status: :created)
    def empty; end
    def secret = render({ secret: true })
    def declined = raise(PaymentDeclined, "card")
    def teapot = raise(Teapot)
    def boom = raise("kaboom")

    def twice
      render({})
      render({ again: true })
    end

    def custom_headers = render({ ok: true }, headers: { "cache-control" => "max-age=60" })
    def echo = render(params.to_h)

    private

    def load_item = @item = { id: params[:id].to_i, time: Time.utc(2026, 1, 2, 3, 4, 5) }
  end

  def app
    router = GemStack::HTTP::Router.new(prefix: "/api", resolver: ->(_) { ItemsController }).draw do
      get "/items", to: "items#index"
      get "/items/:id", to: "items#show"
      post "/items", to: "items#create"
      %w[empty secret declined teapot boom twice custom_headers echo helper_visible_as_action private_thing]
        .each { |a| get "/#{a}", to: "items##{a}" }
    end
    config = build_config
    GemStack::HTTP::App.new(config: config, router: router)
  end

  def test_render_collection
    get "/api/items"

    assert_equal 200, last_response.status
    assert_equal "application/json; charset=utf-8", last_response.content_type
    assert_equal [{ "id" => 1 }, { "id" => 2 }], json(last_response)
  end

  def test_before_callback_and_time_serialization
    get "/api/items/7"

    assert_equal({ "id" => 7, "time" => "2026-01-02T03:04:05.000Z" }, json(last_response))
  end

  def test_json_body_and_symbolic_status
    post "/api/items", JSON.generate(item: { name: "Lamp", admin: true }), "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
    assert_equal({ "name" => "Lamp" }, json(last_response))
  end

  def test_form_body
    post "/api/items", { item: { name: "Form" } }

    assert_equal({ "name" => "Form" }, json(last_response))
  end

  def test_missing_parameter_is_400_with_errors
    post "/api/items", "{}", "CONTENT_TYPE" => "application/json"

    assert_equal 400, last_response.status
    assert_equal "parameter_missing", json(last_response)["error"]["code"]
    assert_equal({ "item" => ["is required"] }, json(last_response)["errors"])
  end

  def test_invalid_json_is_400
    post "/api/items", "{nope", "CONTENT_TYPE" => "application/json"

    assert_equal 400, last_response.status
    assert_equal "invalid_json", json(last_response)["error"]["code"]
  end

  def test_deeply_nested_json_is_rejected
    post "/api/items", ("[" * 100) + ("]" * 100), "CONTENT_TYPE" => "application/json"

    assert_equal 400, last_response.status
  end

  def test_no_render_is_204
    get "/api/empty"

    assert_equal 204, last_response.status
    assert_empty last_response.body
  end

  def test_before_callback_halts
    get "/api/secret"

    assert_equal 401, last_response.status
    get "/api/secret", {}, "HTTP_AUTHORIZATION" => "x"

    assert_equal 200, last_response.status
  end

  def test_after_callback
    get "/api/items"

    assert_equal "1", last_response.headers["x-after"]
  end

  def test_rescue_from_inherited_block
    get "/api/declined"

    assert_equal 402, last_response.status
    assert_equal({ "declined" => "card" }, json(last_response))
  end

  def test_rescue_from_status
    get "/api/teapot"

    assert_equal 504, last_response.status
    assert_equal "gateway_timeout", json(last_response)["error"]["code"]
  end

  def test_unhandled_exception_is_500_with_details_in_test
    get "/api/boom"

    assert_equal 500, last_response.status
    body = json(last_response)

    assert_equal "internal_error", body["error"]["code"]
    assert_equal "kaboom", body["exception"]["message"]
    assert_equal last_response.headers["x-request-id"], body["error"]["request_id"]
  end

  def test_double_render
    get "/api/twice"

    assert_equal 500, last_response.status
    assert_equal "GemStack::HTTP::Controller::DoubleRenderError", json(last_response)["exception"]["class"]
  end

  def test_custom_headers
    get "/api/custom_headers"

    assert_equal "max-age=60", last_response.headers["cache-control"]
  end

  def test_params_merge_query_body_and_path
    get "/api/items/3?extra=1"

    assert_equal 200, last_response.status
    get "/api/echo?q=search"

    assert_equal({ "q" => "search" }, json(last_response))
  end

  def test_non_public_methods_are_not_actions
    get "/api/private_thing"

    assert_equal 500, last_response.status
    assert_includes json(last_response)["exception"]["message"], "not a public action"
  end

  def test_action_methods
    assert_includes ItemsController.action_methods, "index"
    assert_includes ItemsController.action_methods, "helper_visible_as_action"
    refute_includes ItemsController.action_methods, "load_item"
    refute_includes ItemsController.action_methods, "render"
  end
end
