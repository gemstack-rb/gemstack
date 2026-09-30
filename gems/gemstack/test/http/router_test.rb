# frozen_string_literal: true

require "test_helper"

class RouterTest < Minitest::Test
  include HTTPTestHelpers

  Router = GemStack::HTTP::Router

  def router(prefix: "/api", &)
    Router.new(prefix: prefix, resolver: ->(name) { name }).draw(&)
  end

  def target(router, verb, path)
    route, params = router.recognize(verb, path)
    route && [route.target, params]
  end

  def test_static_and_dynamic_routes_under_prefix
    r = router do
      get "/status", to: "status#show"
      get "/products/:id", to: "products#show"
    end

    assert_equal ["status#show", {}], target(r, "GET", "/api/status")
    assert_equal ["products#show", { "id" => "42" }], target(r, "GET", "/api/products/42")
    assert_nil target(r, "GET", "/status")
    assert_nil target(r, "POST", "/api/status")
  end

  def test_trailing_slash_and_double_slashes_are_normalized
    r = router { get "/status", to: "status#show" }

    assert_equal "status#show", target(r, "GET", "/api/status/").first
    assert_equal "status#show", target(r, "GET", "/api//status").first
  end

  def test_empty_prefix_and_root_route
    r = router(prefix: "") { get "/", to: "home#show" }

    assert_equal "home#show", target(r, "GET", "/").first
    assert_equal "/api", router { get "/", to: "home#show" }.routes.first.path
  end

  def test_resources
    r = router { resources :products }
    table = r.routes.map { |route| "#{route.verb} #{route.path} #{route.target}" }

    assert_equal [
      "GET /api/products products#index",
      "POST /api/products products#create",
      "GET /api/products/:id products#show",
      "PATCH /api/products/:id products#update",
      "PUT /api/products/:id products#update",
      "DELETE /api/products/:id products#destroy"
    ], table
  end

  def test_resources_only_except_path_and_controller
    r = router do
      resources :inventory_items, only: %i[index show], path: "/inventory"
      resources :orders, except: %i[destroy update], controller: "purchases"
    end

    assert_equal ["inventory_items#show", { "id" => "1" }], target(r, "GET", "/api/inventory/1")
    assert_equal "purchases#create", target(r, "POST", "/api/orders").first
    assert_nil target(r, "DELETE", "/api/orders/1")
  end

  def test_default_resource_paths_are_dasherized
    r = router { resources :line_items, only: :index }

    assert_equal "/api/line-items", r.routes.first.path
  end

  def test_nested_member_and_collection
    r = router do
      resources :products, only: :show do
        member { post "/publish", action: :publish }
        collection { get "/search", action: :search }
        resources :reviews, only: %i[index create]
      end
    end

    assert_equal ["products#publish", { "id" => "5" }], target(r, "POST", "/api/products/5/publish")
    assert_equal ["products#search", {}], target(r, "GET", "/api/products/search")
    assert_equal ["reviews#index", { "product_id" => "5" }], target(r, "GET", "/api/products/5/reviews")
  end

  def test_static_segment_beats_param
    r = router do
      get "/products/:id", to: "products#show"
      get "/products/featured", to: "products#featured"
    end

    assert_equal "products#featured", target(r, "GET", "/api/products/featured").first
    assert_equal "products#show", target(r, "GET", "/api/products/9").first
  end

  def test_backtracking_between_static_and_param_branches
    r = router do
      get "/a/b/c", to: "x#static"
      get "/a/:id/d", to: "x#param"
    end

    assert_equal ["x#param", { "id" => "b" }], target(r, "GET", "/api/a/b/d")
  end

  def test_namespace_and_scope
    r = router do
      namespace :admin do
        resources :orders, only: :index
      end
      scope "/v2", module: "v2" do
        get "/ping", to: "ping#show"
      end
    end

    assert_equal "admin/orders#index", target(r, "GET", "/api/admin/orders").first
    assert_equal "v2/ping#show", target(r, "GET", "/api/v2/ping").first
  end

  def test_glob_and_percent_decoding
    r = router do
      get "/files/*path", to: "files#show"
      get "/tags/:name", to: "tags#show"
    end

    assert_equal ["files#show", { "path" => "a/b/c.txt" }], target(r, "GET", "/api/files/a/b/c.txt")
    assert_nil target(r, "GET", "/api/files")
    assert_equal({ "name" => "hello world" }, target(r, "GET", "/api/tags/hello%20world").last)
  end

  def test_rack_app_endpoints_and_mount
    app = ->(env) { [200, {}, [env["PATH_INFO"]]] }
    r = router do
      get "/ping", to: app
      mount app, at: "/hooks"
    end

    assert_equal ["/api/ping"], r.call(env_for("/api/ping"))[2]
    assert_equal ["/api/hooks"], r.call(env_for("/api/hooks", method: "POST"))[2]
    assert_equal ["/api/hooks/stripe/1"], r.call(env_for("/api/hooks/stripe/1"))[2]
  end

  def test_duplicate_routes_raise
    assert_raises(ArgumentError) { router { 2.times { get "/x", to: "x#y" } } }
    assert_raises(ArgumentError) { router { 2.times { get "/x/:id", to: "x#y" } } }
  end

  def test_invalid_definitions_raise
    assert_raises(ArgumentError) { router { get "/x", to: "nohash" } }
    assert_raises(ArgumentError) { router { get "/x" } }
    assert_raises(ArgumentError) { router { get "/*a/b", to: "x#y" } }
  end

  def test_unknown_verbs_do_not_allocate_route_tables
    r = router { get "/x", to: "x#y" }
    r.recognize("BREW", "/api/x")

    assert_equal ["GET"], r.allowed_verbs("/api/x")
  end

  def test_not_found_and_method_not_allowed
    r = router { get "/x", to: "x#y" }

    error = assert_raises(GemStack::NotFound) { r.call(env_for("/api/nope")) }
    assert_equal "route_not_found", error.code

    error = assert_raises(GemStack::MethodNotAllowed) { r.call(env_for("/api/x", method: "DELETE")) }
    assert_equal "GET, HEAD", error.headers["allow"]
  end

  def test_head_falls_back_to_get_without_body
    app = ->(_env) { [200, { "content-type" => "text/plain" }, ["hello"]] }
    r = router { get "/x", to: app }
    status, _headers, body = r.call(env_for("/api/x", method: "HEAD"))

    assert_equal 200, status
    assert_empty body.to_a
  end

  def test_resolves_controller_constants
    stub = Class.new { def self.dispatch(action, _env) = [200, {}, [action]] }
    Object.const_set(:WidgetsController, stub)
    r = Router.new(prefix: "/api").draw { get "/widgets", to: "widgets#index" }

    assert_equal ["index"], r.call(env_for("/api/widgets"))[2]
  ensure
    Object.send(:remove_const, :WidgetsController)
  end

  def test_missing_controller_is_a_configuration_error
    r = Router.new(prefix: "/api").draw { get "/ghosts", to: "ghosts#index" }

    error = assert_raises(GemStack::ConfigurationError) { r.call(env_for("/api/ghosts")) }
    assert_includes error.message, "GhostsController"
  end
end
