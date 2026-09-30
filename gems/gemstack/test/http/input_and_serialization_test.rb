# frozen_string_literal: true

require "test_helper"

class InputAndSerializationTest < Minitest::Test
  include Rack::Test::Methods
  include HTTPTestHelpers

  Gadget = Struct.new(:id, :name, :price, :secret)

  class GadgetSerializer < GemStack::Serializer
    attributes id: :integer, name: :string, price: :decimal
    attribute(:viewer, :string) { |_| context[:viewer] }
  end

  class PlainSerializer < GemStack::Serializer
    attributes name: :string
  end

  # Mimics a Sequel dataset: responds to #model and #all.
  FakeDataset = Struct.new(:items) do
    def model = Gadget
    def all = items
  end

  class GadgetInput < GemStack::Schema
    required :name, :string
    required :price, :decimal, gt: 0
  end

  class GadgetsController < GemStack::HTTP::Controller
    accepts :create, with: GadgetInput
    accepts :update, with: GadgetInput, partial: true
    accepts(:search) { required :q, :string }
    returns :search, [GadgetSerializer]

    GADGET = Gadget.new(1, "Lamp", BigDecimal("9.5"), "hidden")

    def show = render(GADGET)
    def index = render([GADGET, GADGET])
    def dataset = render(FakeDataset.new([GADGET]))
    def plain = render(GADGET, serializer: PlainSerializer)
    def create = render(input, status: :created)
    def update = render(input)
    def search = render({ q: input[:q] })
    def adhoc = render(params.validate { required :n, :integer })
    def missing = render(input)

    private

    def serializer_context = { viewer: "tester" }
  end

  def app
    router = GemStack::HTTP::Router.new(prefix: "/api", resolver: ->(_) { GadgetsController }).draw do
      %w[show index dataset plain search adhoc missing].each { |a| get "/#{a}", to: "gadgets##{a}" }
      post "/gadgets", to: "gadgets#create"
      patch "/gadgets/:id", to: "gadgets#update"
    end
    GemStack::HTTP::App.new(config: build_config, router: router)
  end

  def post_json(path, body, verb: :post)
    public_send(verb, path, JSON.generate(body), "CONTENT_TYPE" => "application/json")
  end

  def test_convention_serializer_hides_unlisted_fields
    get "/api/show"

    assert_equal({ "id" => 1, "name" => "Lamp", "price" => "9.5", "viewer" => "tester" }, json(last_response))
  end

  def test_arrays_and_datasets_use_the_serializer
    get "/api/index"

    assert_equal(%w[Lamp Lamp], json(last_response).map { |g| g["name"] })
    get "/api/dataset"

    refute json(last_response).first.key?("secret")
  end

  def test_explicit_serializer
    get "/api/plain"

    assert_equal({ "name" => "Lamp" }, json(last_response))
  end

  def test_input_is_validated_and_coerced
    post_json "/api/gadgets", { name: "Lamp", price: "12.50", admin: true }

    assert_equal 201, last_response.status
    assert_equal({ "name" => "Lamp", "price" => "12.5" }, json(last_response))
  end

  def test_invalid_input_is_422
    post_json "/api/gadgets", { price: "-1" }

    assert_equal 422, last_response.status
    body = json(last_response)

    assert_equal "validation_failed", body["error"]["code"]
    assert_equal({ "name" => ["is required"], "price" => ["must be greater than 0"] }, body["errors"])
  end

  def test_partial_input_for_updates
    post_json "/api/gadgets/1", { price: "3" }, verb: :patch

    assert_equal({ "price" => "3.0" }, json(last_response))
  end

  def test_block_schemas_and_adhoc_validation
    get "/api/search?q=lamp"

    assert_equal({ "q" => "lamp" }, json(last_response))
    get "/api/adhoc?n=x"

    assert_equal({ "n" => ["must be an integer"] }, json(last_response)["errors"])
  end

  def test_input_without_accepts_is_a_clear_error
    get "/api/missing"

    assert_equal 500, last_response.status
    assert_includes json(last_response)["exception"]["message"], "no `accepts` declaration"
  end

  def test_contract_metadata
    assert_equal GadgetInput, GadgetsController.input_schemas["create"]
    assert_equal [:price], GadgetsController.input_schemas["update"].fields.keys - [:name]
    refute GadgetsController.input_schemas["update"].fields[:name].required
    assert_equal [GadgetSerializer], GadgetsController.response_types["search"]
  end

  def test_error_mapping_is_applied
    klass = Class.new(StandardError)
    GemStack::ErrorMapping.register(klass) { GemStack::Conflict.new("taken") }
    status, _, body = GemStack::HTTP::ErrorRenderer.render(klass.new)

    assert_equal 409, status
    assert_equal "taken", JSON.parse(body.join)["error"]["message"]
  ensure
    GemStack::ErrorMapping.unregister(klass)
  end
end
