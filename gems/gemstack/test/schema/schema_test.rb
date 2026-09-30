# frozen_string_literal: true

require "test_helper"

class TypesTest < Minitest::Test
  T = GemStack::Types

  def coerce(type, value) = T.fetch(type).coerce(value)

  def test_coercions
    assert_equal 12, coerce(:integer, " 12 ")
    assert_equal 3, coerce(:integer, 3.0)
    assert_in_delta 1.5, coerce(:float, "1.5")
    assert_equal BigDecimal("9.99"), coerce(:decimal, "9.99")
    assert_equal BigDecimal("0.1"), coerce(:decimal, 0.1)
    assert coerce(:boolean, "true")
    refute coerce(:boolean, "0")
    assert_equal Date.new(2026, 2, 3), coerce(:date, "2026-02-03")
    assert_equal Time.utc(2026, 2, 3, 4, 5, 6), coerce(:datetime, "2026-02-03T04:05:06Z")
    assert_equal Time.utc(2026, 2, 3, 4, 5), coerce(:datetime, "2026-02-03T04:05")
    assert_equal "abc", coerce(:string, :abc)
  end

  def test_coercion_failures
    {
      integer: ["1.5", "x", 1.5, nil], float: ["abc", []], decimal: ["1,5", {}], boolean: ["maybe", 2],
      date: ["03/02/2026"], datetime: ["tomorrow"], uuid: ["123"], string: [{}]
    }.each do |type, values|
      values.each { |value| assert_raises(T::CoercionError, "#{type} #{value.inspect}") { coerce(type, value) } }
    end
  end

  def test_dumping
    assert_equal "9.99", T.fetch(:decimal).dump(BigDecimal("9.990"))
    assert_equal "2026-01-02T03:04:05.000Z", T.fetch(:datetime).dump(Time.new(2026, 1, 2, 4, 4, 5, "+01:00"))
    assert_equal "2026-01-02", T.fetch(:date).dump(Date.new(2026, 1, 2))
    assert_nil T.fetch(:decimal).dump(nil)
  end

  def test_class_aliases_and_unknown_types
    assert_equal :integer, T.fetch(Integer).name
    assert_equal :decimal, T.fetch(BigDecimal).name
    assert_raises(ArgumentError) { T.fetch(:money) }
  end

  def test_typescript_mapping
    assert_equal({ string: "string", integer: "number", decimal: "string", boolean: "boolean", json: "unknown" },
                 %i[string integer decimal boolean json].to_h { |t| [t, T.fetch(t).ts] })
  end
end

class SchemaTest < Minitest::Test
  class ProductInput < GemStack::Schema
    required :name, :string, max_length: 5
    required :price, :decimal, gt: 0
    optional :active, :boolean, default: true
    optional :stock, Integer, gte: 0
    optional :tags, [:string]
    optional :color, :string, in: %w[red blue]
    optional :note, :text, nullable: true
    optional :dimensions do
      required :width, :integer
      optional :height, :integer
    end
    optional :variants, :array do
      required :sku, :string, format: /\A[A-Z]+\z/
    end
  end

  def call(input) = ProductInput.call(input)

  def errors_for(input)
    error = assert_raises(GemStack::ValidationError) { call(input) }
    assert_equal 422, error.status
    error.errors
  end

  def test_valid_input_is_coerced_and_allow_listed
    result = call("name" => "Lamp", "price" => "9.99", "stock" => "3", "tags" => %w[a b], "admin" => true,
                  "dimensions" => { "width" => "10", "evil" => 1 }, "variants" => [{ "sku" => "AB" }])

    assert_equal({ name: "Lamp", price: BigDecimal("9.99"), active: true, stock: 3, tags: %w[a b],
                   dimensions: { width: 10 }, variants: [{ sku: "AB" }] }, result)
  end

  def test_symbol_keys_and_params_objects_are_accepted
    params = Struct.new(:h) { def to_unsafe_h = h }.new({ "name" => "A", "price" => 1 })

    assert_equal "A", call(name: "A", price: 1)[:name]
    assert_equal "A", call(params)[:name]
  end

  def test_required_fields
    assert_equal({ "name" => ["is required"], "price" => ["is required"] }, errors_for({}))
    assert_equal ["is required"], errors_for("name" => "  ", "price" => 1)["name"]
    assert_equal ["is required"], errors_for("name" => "A", "price" => nil)["price"]
  end

  def test_rules_and_types
    errors = errors_for("name" => "Too long", "price" => "0", "stock" => "-1", "color" => "green", "tags" => "x",
                        "dimensions" => { "width" => "wide" }, "variants" => [{ "sku" => "ok" }, {}])

    assert_equal ["is too long (maximum 5 characters)"], errors["name"]
    assert_equal ["must be greater than 0"], errors["price"]
    assert_equal ["must be greater than or equal to 0"], errors["stock"]
    assert_equal ["must be one of: red, blue"], errors["color"]
    assert_equal ["must be a list"], errors["tags"]
    assert_equal ["must be an integer"], errors["dimensions.width"]
    assert_equal ["is invalid"], errors["variants.0.sku"]
    assert_equal ["is required"], errors["variants.1.sku"]
  end

  def test_nulls
    assert_nil call("name" => "A", "price" => 1, "note" => nil)[:note]
    assert_equal ["can't be null"], errors_for("name" => "A", "price" => 1, "stock" => nil)["stock"]
  end

  def test_empty_form_values_count_as_absent_for_non_strings
    result = call("name" => "A", "price" => "1", "stock" => "", "active" => "")

    refute result.key?(:stock)
    assert result[:active]
  end

  def test_non_object_input
    assert_equal({ "base" => ["must be an object"] }, errors_for([1, 2]))
  end

  def test_validate_returns_errors
    result, errors = ProductInput.validate("name" => "A")

    assert_nil result
    assert_equal ["is required"], errors["price"]
  end

  def test_partial_makes_everything_optional
    partial = ProductInput.partial("ProductUpdate")

    assert_equal({ price: BigDecimal(2) }, partial.call("price" => "2"))
    assert_equal "ProductUpdate", partial.type_name
    assert_equal ["must be greater than 0"], assert_raises(GemStack::ValidationError) { partial.call("price" => -1) }
      .errors["price"]
  end

  def test_define_and_inheritance
    schema = GemStack::Schema.define("Search") { required :q, :string }
    child = Class.new(schema) { optional :page, :integer, default: 1 }

    assert_equal({ q: "x", page: 1 }, child.call("q" => "x"))
    assert_equal %i[q], schema.fields.keys
  end

  def test_from_model
    schema = GemStack::Schema.from_model(FakeProduct, except: :description)

    assert_equal %i[name price active stock], schema.fields.keys
    assert schema.fields[:name].required
    refute schema.fields[:active].required
    refute schema.fields[:stock].required
    assert_equal ["is too long (maximum 120 characters)"],
                 assert_raises(GemStack::ValidationError) {
                   schema.call("name" => "x" * 121, "price" => 1)
                 }.errors["name"]
    assert_equal ["must be greater than or equal to 0"],
                 assert_raises(GemStack::ValidationError) { schema.call("name" => "x", "price" => 1, "stock" => -1) }
                   .errors["stock"]
  end

  def test_invalid_definitions
    assert_raises(ArgumentError) { GemStack::Schema.define { required :x, :money } }
    assert_raises(ArgumentError) { GemStack::Schema.define { required :x, :string, maximum: 3 } }
    assert_raises(ArgumentError) { GemStack::Schema.define { required :x } }
  end
end

class SerializerTest < Minitest::Test
  class CategorySerializer < GemStack::Serializer
    attributes name: :string
  end

  class FakeProductSerializer < GemStack::Serializer
    model FakeProduct
    attributes :id, :name, :price, :description, :active, :created_at
    attribute :label, :string do |product|
      "#{product.name} (#{context[:currency]})"
    end
    attribute :category, CategorySerializer
    attribute :tags, [:string]
  end

  Category = Struct.new(:name)

  def product(**overrides)
    FakeProduct.new(id: 1, name: "Lamp", price: BigDecimal("9.90"), description: nil, active: true,
                    created_at: Time.utc(2026, 1, 2), **overrides).tap do |p|
      p.define_singleton_method(:category) { Category.new("Home") }
      p.define_singleton_method(:tags) { %i[a b] }
    end
  end

  def test_serialize
    expected = { id: 1, name: "Lamp", price: "9.9", description: nil, active: true,
                 created_at: "2026-01-02T00:00:00.000Z", label: "Lamp (EUR)", category: { name: "Home" },
                 tags: %w[a b] }

    assert_equal expected, FakeProductSerializer.serialize(product, currency: "EUR")
    assert_nil FakeProductSerializer.serialize(nil)
  end

  def test_many
    assert_equal 2, FakeProductSerializer.many([product, product]).size
  end

  def test_type_inference
    types = FakeProductSerializer.resolved_attributes.to_h { |a| [a[:name], [a[:type], a[:nullable]]] }

    assert_equal [:bigint, false], types[:id]
    assert_equal [:string, false], types[:name]
    assert_equal [:decimal, false], types[:price]
    assert_equal [:text, true], types[:description]
    assert_equal [:datetime, false], types[:created_at]
    # explicit types are non-null unless declared nullable
    assert_equal [:string, false], types[:label]
    assert_equal [CategorySerializer, false], types[:category]
    assert_equal [[:string], false], types[:tags]
  end

  def test_type_name_and_lookup
    assert_equal "SerializerTestFakeProduct", FakeProductSerializer.type_name
    assert_nil GemStack::Serializer.for(Class.new)
  end

  def test_unknown_types_are_rejected
    assert_raises(ArgumentError) { Class.new(GemStack::Serializer) { attribute :x, :money } }
  end
end
