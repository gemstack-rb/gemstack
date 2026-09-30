# frozen_string_literal: true

require "test_helper"

class CtPartSerializer < GemStack::Serializer
  attributes sku: :string
end

class CtWidgetSerializer < GemStack::Serializer
  attributes id: :bigint, name: :string, price: :decimal
  attribute :notes, :text, nullable: true
  attribute :parts, [CtPartSerializer]
end

class CtWidgetInput < GemStack::Schema
  required :name, :string
  required :price, :decimal
  optional :notes, :text, nullable: true
  optional :size do
    required :width, :integer
  end
  optional :tags, [:string]
end

class CtWidgetsController < GemStack::HTTP::Controller
  accepts :create, with: CtWidgetInput
  accepts :update, with: CtWidgetInput, partial: true
  accepts(:search) { required :q, :string }
  returns :search, [CtWidgetSerializer]
  returns :publish, nil

  def index; end
  def show; end
  def create; end
  def update; end
  def destroy; end
  def search; end
  def publish; end
  def stats; end
end

class CtGadgetsController < GemStack::HTTP::Controller
  returns :index, GemStack::Page[CtPartSerializer]
  accepts(:search) { optional :q, :string }
  returns :search, GemStack::Page[CtPartSerializer]

  def index; end
  def search; end
end

class ContractTest < Minitest::Test
  FakeApp = Struct.new(:routes, :config) do
    def eager_load! = nil
  end

  def app
    router = GemStack::HTTP::Router.new(prefix: "/api").draw do
      resources :ct_widgets, path: "/widgets" do
        collection { get "/search", action: :search }
        member do
          post "/publish", action: :publish
          get "/stats", action: :stats
        end
      end
      get "/ping", to: ->(_) { [200, {}, []] }
      get "/ghosts", to: "ghosts#index"
      resources :ct_gadgets, only: :index do
        collection { get "/search", action: :search }
      end
    end
    config = GemStack::Config.new
    FakeApp.new(router.routes, config)
  end

  def contract = @contract ||= GemStack::Contract.build(app)

  def endpoints(name = "ct_widgets")
    contract[:resources].find { |r| r[:name] == name }[:endpoints].to_h { |e| [e[:name], e] }
  end

  def test_paginated_endpoints
    e = endpoints("ct_gadgets")

    assert e["list"][:paginated]
    assert_equal({ page: { ref: "CtPart" } }, e["list"][:response])
    ts = GemStack::Contract::TypeScript.new(contract).files

    assert_includes ts["types.ts"], "export type Paginated<T> = {"
    assert_includes ts["ct_gadgets.ts"],
                    "list: (query?: PaginationQuery, options?: RequestOptions) => " \
                    "api.get<Paginated<CtPart>>(\"/ct-gadgets\", { ...options, query }),"
    assert_includes ts["ct_gadgets.ts"], "search: (query: CtGadgetSearchInput & PaginationQuery, options?: RequestOptions)"
    assert_includes ts["ct_gadgets.ts"], "import type { CtGadgetSearchInput, CtPart, Paginated, PaginationQuery } from"
    doc = GemStack::Contract::OpenAPI.new(contract).document
    list = doc[:paths]["/api/ct-gadgets"]["get"]

    assert_equal(%w[page per_page], list[:parameters].map { |p| p[:name] })
    assert_equal %i[data meta], list[:responses]["200"][:content]["application/json"][:schema][:properties].keys
  end

  def test_resources_and_conventional_endpoints
    assert_equal(%w[ct_gadgets ct_widgets], contract[:resources].map { |r| r[:name] })
    e = endpoints

    assert_equal %w[create delete get list publish search stats update], e.keys.sort
    assert_equal({ array: { ref: "CtWidget" } }, e["list"][:response])
    assert_equal({ ref: "CtWidget" }, e["get"][:response])
    assert_nil e["delete"][:response]
    assert_nil e["publish"][:response]
    assert_equal ["id"], e["update"][:params]
    assert_equal "PATCH", e["update"][:verb]
    assert_equal({ ref: "CtWidgetInput" }, e["create"][:body])
    assert_equal({ ref: "CtWidgetUpdateInput" }, e["update"][:body])
    assert_equal({ ref: "CtWidgetSearchInput" }, e["search"][:query])
    assert_nil e["search"][:body]
  end

  def test_warnings
    assert(contract[:warnings].any? { |w| w.include?("CtWidgetsController#stats") })
    assert(contract[:warnings].any? { |w| w.include?("GhostsController is not defined") })
  end

  def test_types
    widget = contract[:types]["CtWidget"][:fields].to_h { |f| [f[:name], f] }

    assert_equal({ scalar: :decimal }, widget["price"][:type])
    assert widget["notes"][:nullable]
    assert_equal({ array: { ref: "CtPart" } }, widget["parts"][:type])
    input = contract[:types]["CtWidgetInput"][:fields].to_h { |f| [f[:name], f] }

    refute input["name"][:optional]
    assert input["notes"][:optional]
    assert_equal({ object: [{ name: "width", type: { scalar: :integer }, nullable: false, optional: false }] },
                 input["size"][:type])
    assert(contract[:types]["CtWidgetUpdateInput"][:fields].all? { |f| f[:optional] })
  end

  def test_typescript_types
    ts = GemStack::Contract::TypeScript.new(contract).files["types.ts"]

    assert_includes ts, GemStack::Contract::HEADER
    assert_includes ts, <<~TS
      export type CtWidget = {
        id: number;
        name: string;
        price: string;
        notes: string | null;
        parts: CtPart[];
      };
    TS
    assert_includes ts, "  notes?: string | null;"
    assert_includes ts, "  size?: {\n    width: number;\n  };"
    assert_includes ts, "  tags?: string[];"
  end

  def test_typescript_client
    ts = GemStack::Contract::TypeScript.new(contract).files["ct_widgets.ts"]

    assert_includes ts, %(import { api, type RequestOptions } from "@/lib/gemstack/client";)
    assert_includes ts,
                    %(import type { CtWidget, CtWidgetInput, CtWidgetSearchInput, CtWidgetUpdateInput } from "./types";)
    assert_includes ts, "export const ctWidgets = {"
    assert_includes ts, %(list: (options?: RequestOptions) => api.get<CtWidget[]>("/widgets", options),)
    assert_includes ts,
                    "get: (id: string | number, options?: RequestOptions) => api.get<CtWidget>(`/widgets/${segment(id)}`, options),"
    assert_includes ts,
                    %(create: (data: CtWidgetInput, options?: RequestOptions) => api.post<CtWidget>("/widgets", data, options),)
    assert_includes ts, "update: (id: string | number, data: CtWidgetUpdateInput, options?: RequestOptions) => " \
                        "api.patch<CtWidget>(`/widgets/${segment(id)}`, data, options),"
    assert_includes ts,
                    "delete: (id: string | number, options?: RequestOptions) => api.delete<void>(`/widgets/${segment(id)}`, options),"
    assert_includes ts,
                    %(search: (query: CtWidgetSearchInput, options?: RequestOptions) => api.get<CtWidget[]>("/widgets/search", { ...options, query }),)
    assert_includes ts,
                    "publish: (id: string | number, options?: RequestOptions) => api.post<void>(`/widgets/${segment(id)}/publish`, undefined, options),"
    assert_includes ts, "stats: (id: string | number, options?: RequestOptions) => api.get<unknown>("
  end

  def test_index_file
    ts = GemStack::Contract::TypeScript.new(contract).files["index.ts"]

    assert_includes ts, %(export type * from "./types";)
    assert_includes ts, %(export { ctWidgets } from "./ct_widgets";)
  end

  def test_openapi
    doc = GemStack::Contract::OpenAPI.new(contract, title: "shop").document

    assert_equal "3.1.0", doc[:openapi]
    widget = doc[:paths]["/api/widgets/{id}"]

    assert_equal %w[delete get patch], widget.keys.sort
    assert_equal({ "$ref": "#/components/schemas/CtWidget" },
                 widget["get"][:responses]["200"][:content]["application/json"][:schema])
    assert_equal "201", doc[:paths]["/api/widgets"]["post"][:responses].keys.first
    assert_equal({ type: "string", format: "decimal" }, doc[:components][:schemas]["CtWidget"][:properties]["price"])
    assert_equal %w[name price], doc[:components][:schemas]["CtWidgetInput"][:required]
    assert_equal "q", doc[:paths]["/api/widgets/search"]["get"][:parameters].first[:name]
    assert doc[:components][:schemas]["Error"]
  end

  def test_a_user_type_named_like_generated_helpers_is_refused
    serializer = Class.new(GemStack::Serializer) { attributes id: :integer }
    serializer.type_name = "Paginated"
    Object.const_set(:CtClashController, Class.new(GemStack::HTTP::Controller) do
      define_method(:show) { nil }
    end)
    Object.const_set(:CtClashSerializer, serializer)
    router = GemStack::HTTP::Router.new(prefix: "/api").draw { get "/clash/:id", to: "ct_clash#show" }

    error = assert_raises(GemStack::ConfigurationError) do
      GemStack::Contract.build(FakeApp.new(router.routes, GemStack::Config.new))
    end
    assert_includes error.message, "Paginated"
  ensure
    %i[CtClashController CtClashSerializer].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
  end

  def test_write_only_touches_changed_files_and_removes_stale_ones
    Dir.mktmpdir do |root|
      first = GemStack::Contract.write(contract, root: root)

      assert_equal 5, first[:written].size # types, index, 2 resources, openapi
      stale = File.join(root, "frontend/lib/api/generated/old_resource.ts")
      File.write(stale, "// #{GemStack::Contract::HEADER}\n")
      mine = File.join(root, "frontend/lib/api/generated/handwritten.ts")
      File.write(mine, "export const x = 1;\n")
      second = GemStack::Contract.write(contract, root: root)

      assert_empty second[:written]
      assert_equal [stale], second[:removed]
      assert File.exist?(mine)
      assert JSON.parse(File.read(File.join(root, "openapi.json")))["paths"]
    end
  end

  def test_an_app_without_routes_still_compiles
    empty = { api_path: "/api", types: {}, resources: [], warnings: [] }
    files = GemStack::Contract::TypeScript.new(empty).files

    assert_includes files["types.ts"], "export {};"
  end
end
