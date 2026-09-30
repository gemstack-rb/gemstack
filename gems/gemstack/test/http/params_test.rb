# frozen_string_literal: true

require "test_helper"

class ParamsTest < Minitest::Test
  Params = GemStack::HTTP::Params

  def params
    Params.new(
      "id" => "3",
      "product" => {
        "name" => "Lamp", "price" => "9.99", "admin" => true,
        "tags" => ["home", "light", { "evil" => 1 }],
        "dimensions" => { "width" => 3, "height" => 5, "secret" => "x" },
        "variants" => [{ "sku" => "A", "hidden" => 1 }, { "sku" => "B" }],
        "meta" => { "nested" => true }
      },
      "blank" => "  "
    )
  end

  def test_indifferent_access
    assert_equal "3", params[:id]
    assert_equal "3", params["id"]
    assert_kind_of Params, params[:product]
    assert_equal "Lamp", params[:product][:name]
    assert_equal "Lamp", params.dig(:product, :name)
    assert params.key?(:id)
  end

  def test_require
    assert_equal "Lamp", params.require(:product)[:name]

    error = assert_raises(Params::ParameterMissing) { params.require(:missing) }
    assert_equal 400, error.status
    assert_equal({ "missing" => ["is required"] }, error.details)
    assert_raises(Params::ParameterMissing) { params.require(:blank) }
  end

  def test_permit_scalars_only
    permitted = params.require(:product).permit(:name, :price, :meta, :missing)

    assert_equal({ name: "Lamp", price: "9.99" }, permitted)
  end

  def test_permit_nested_structures
    permitted = params.require(:product).permit(:name, tags: [], dimensions: %i[width height], variants: [:sku])

    assert_equal %w[home light], permitted[:tags]
    assert_equal({ width: 3, height: 5 }, permitted[:dimensions])
    assert_equal [{ sku: "A" }, { sku: "B" }], permitted[:variants]
  end

  def test_to_h_is_a_deep_copy
    raw = params.to_h
    raw["product"]["name"] = "changed"

    assert_equal "Lamp", params[:product][:name]
  end

  def test_fetch_slice_except
    assert_equal "d", params.fetch(:nope, "d")
    assert_equal ["id"], params.slice(:id).keys
    refute params.except(:id).key?(:id)
  end
end
