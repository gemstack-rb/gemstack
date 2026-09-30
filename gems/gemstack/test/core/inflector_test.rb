# frozen_string_literal: true

require "test_helper"

class InflectorTest < Minitest::Test
  I = GemStack::Inflector

  PAIRS = {
    "product" => "products", "category" => "categories", "box" => "boxes", "status" => "statuses",
    "person" => "people", "child" => "children", "address" => "addresses", "wife" => "wives",
    "half" => "halves", "day" => "days", "quiz" => "quizzes", "index" => "indices",
    "analysis" => "analyses", "equipment" => "equipment", "line_item" => "line_items",
    "sales_person" => "sales_people", "LineItem" => "LineItems", "virus" => "viruses",
    "movie" => "movies", "hero" => "heroes"
  }.freeze

  def test_pluralize_and_singularize
    PAIRS.each do |singular, plural|
      assert_equal plural, I.pluralize(singular), "pluralize #{singular}"
      assert_equal singular, I.singularize(plural), "singularize #{plural}"
    end
  end

  def test_idempotent
    assert_equal "products", I.pluralize("products")
    assert_equal "people", I.pluralize("people")
    assert_equal "person", I.singularize("person")
  end

  def test_case_conversion
    assert_equal "InventoryItem", I.camelize("inventory_item")
    assert_equal "Admin::Products", I.camelize("admin/products")
    assert_equal "inventory_item", I.underscore("InventoryItem")
    assert_equal "admin/html_parser", I.underscore("Admin::HTMLParser")
    assert_equal "inventory-item", I.dasherize("InventoryItem")
    assert_equal "Author", I.humanize("author_id")
    assert_equal "InventoryItem", I.classify("inventory_items")
    assert_equal "inventory_items", I.tableize("InventoryItem")
  end

  def test_custom_irregular
    I.irregular("octopus", "octopodes")

    assert_equal "octopodes", I.pluralize("octopus")
  end
end
