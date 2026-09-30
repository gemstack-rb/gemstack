# frozen_string_literal: true

ENV["GEMSTACK_ENV"] = "test"
require "gemstack/schema"
require "minitest/autorun"

# Stands in for a model class: anything with #gemstack_fields works.
FakeField = Struct.new(:name, :type, :options)
class FakeProduct
  FIELDS = {
    name: FakeField.new(:name, :string, { null: false, size: 120 }),
    price: FakeField.new(:price, :decimal, { null: false }),
    description: FakeField.new(:description, :text, {}),
    active: FakeField.new(:active, :boolean, { null: false, default: true }),
    stock: FakeField.new(:stock, :integer, { null: false, default: 0, gte: 0 })
  }.freeze

  def self.gemstack_fields = FIELDS

  attr_reader :id, :name, :price, :description, :active, :created_at

  def initialize(**attrs) = attrs.each { |k, v| instance_variable_set(:"@#{k}", v) }
end
