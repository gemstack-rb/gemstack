# frozen_string_literal: true

require "test_helper"

# Models are defined once against real tables created here.
module ModelFixtures
  def self.install!
    return if @installed

    db = GemStack::DB.connection
    db.drop_table?(:mt_products, :mt_categories, cascade: GemStack::DB.postgres?)
    db.create_table(:mt_categories) do
      primary_key :id, type: :Bignum
      String :name, null: false, unique: true
    end
    db.create_table(:mt_products) do
      primary_key :id, type: :Bignum
      foreign_key :category_id, :mt_categories, type: :Bignum
      String :name, null: false
      String :sku, unique: true
      BigDecimal :price, size: [10, 2], null: false
      TrueClass :active, null: false, default: true
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
    end

    Object.const_set(:MtCategory, Class.new(GemStack::Model(:mt_categories)))
    Object.const_set(:MtProduct, Class.new(GemStack::Model(:mt_products)) do
      field :name, :string, null: false, size: 10
      field :sku, :string, format: /\A[A-Z0-9]+\z/
      field :price, :decimal, null: false, gt: 0
      field :active, :boolean, null: false, default: true
      field :category_id, :references
      validates :name, length: { min: 2 }
      belongs_to :category, class: "MtCategory"
    end)
    Object.const_set(:MtProductSerializer, Class.new(GemStack::Serializer) do
      attributes :id, :name, :price, :active, :created_at
    end)
    @installed = true
  end
end

# Outside any test, so no transactional test can roll the tables back.
ModelFixtures.install! if DBTest.available?

class ModelTest < Minitest::Test
  include DBTest

  def setup
    super
    db[:mt_products].delete
    db[:mt_categories].delete
  end

  def render_error(&)
    yield
    flunk "expected an exception"
  rescue StandardError => e
    GemStack::ErrorMapping.translate(e)
  end

  def test_create_sets_timestamps_and_types
    product = MtProduct.create(name: "Lamp", price: "9.99")

    assert product.id
    assert_equal BigDecimal("9.99"), product.price
    assert product.active
    assert_kind_of Time, product.created_at
    assert_equal product.created_at, product.updated_at
  end

  def test_field_validations
    product = MtProduct.new(name: "", price: 0, sku: "bad sku")

    refute_predicate product, :valid?
    assert_equal({ name: ["is required", "is too short (minimum 2 characters)"], price: ["must be greater than 0"],
                   sku: ["is invalid"] }, product.errors.to_h)
  end

  def test_validation_failure_maps_to_422_envelope
    error = render_error { MtProduct.create!(name: "x" * 11, price: 1) }

    assert_kind_of GemStack::ValidationError, error
    assert_equal({ "name" => ["is too long (maximum 10 characters)"] }, error.errors)
  end

  def test_find
    product = MtProduct.create(name: "Lamp", price: 1)

    assert_equal product, MtProduct.find(product.id)
    assert_equal product, MtProduct.find(product.id.to_s)
    assert_raises(GemStack::DB::RecordNotFound) { MtProduct.find(product.id + 1000) }
    assert_raises(GemStack::DB::RecordNotFound) { MtProduct.find("abc") }
    assert_raises(GemStack::DB::RecordNotFound) { MtProduct.find("1; DROP TABLE mt_products") }
    assert_equal product, MtProduct.find(name: "Lamp")
    assert_nil MtProduct.find(name: "nope")
    assert_equal 404, GemStack::ErrorMapping.translate(GemStack::DB::RecordNotFound.new).status
  end

  def test_find_by
    MtProduct.create(name: "Lamp", price: 1)

    assert_equal "Lamp", MtProduct.find_by(name: "Lamp").name
    assert_raises(GemStack::DB::RecordNotFound) { MtProduct.find_by!(name: "x") }
  end

  def test_delete_all
    MtProduct.create(name: "Lamp", price: 1)
    MtProduct.create(name: "Table", price: 2)

    assert_equal 2, MtProduct.count

    MtProduct.delete_all

    assert_equal 0, MtProduct.count
  end

  def test_unique_violation_maps_to_field_error
    MtProduct.create(name: "Lamp", price: 1, sku: "A1")
    error = render_error { MtProduct.create(name: "Lamp2", price: 1, sku: "A1") }

    assert_equal({ "sku" => ["is already taken"] }, error.errors)
    assert_equal 422, error.status
  end

  def test_foreign_key_violations
    error = render_error do
      db[:mt_products].insert(name: "x", price: 1, category_id: 999, created_at: Time.now, updated_at: Time.now)
    end

    if GemStack::DB.sqlite? # SQLite doesn't say which side of the key failed
      assert_equal 409, error.status
    else
      assert_equal({ "category_id" => ["does not exist"] }, error.errors)
    end
    category = MtCategory.create(name: "Home")
    MtProduct.create(name: "Lamp", price: 1, category_id: category.id)
    error = render_error { category.destroy }

    assert_equal [409, "still_referenced"], [error.status, error.code]
  end

  def test_not_null_violation_maps_to_field_error
    error = render_error { db[:mt_products].insert(price: 1, created_at: Time.now, updated_at: Time.now) }

    assert_equal({ "name" => ["is required"] }, error.errors)
  end

  def test_no_matching_row_maps_to_404
    error = render_error { MtProduct.where(name: "none").first! }

    assert_equal 404, error.status
  end

  def test_associations
    category = MtCategory.create(name: "Home")
    product = MtProduct.create(name: "Lamp", price: 1, category_id: category.id)

    assert_equal "Home", product.category.name
  end

  def test_input_schema_from_fields
    schema = MtProduct.input_schema

    assert_equal "MtProductInput", schema.type_name
    assert_equal %i[name sku price active category_id], schema.fields.keys
    assert_same schema, MtProduct.input_schema
    # DB defaults (active) are left to PostgreSQL, not injected by the schema.
    assert_equal({ name: "Lamp", price: BigDecimal("2.5") }, schema.call("name" => "Lamp", "price" => "2.5"))
  end

  def test_models_are_not_implicitly_serializable
    error = assert_raises(GemStack::Error) { MtProduct.new.as_json }

    assert_includes error.message, "MtProductSerializer"
  end

  def test_serializer_infers_types_from_fields
    types = MtProductSerializer.resolved_attributes.to_h { |a| [a[:name], a[:type]] }

    assert_equal({ id: :bigint, name: :string, price: :decimal, active: :boolean, created_at: :datetime }, types)
    product = MtProduct.create(name: "Lamp", price: "9.5")

    assert_equal "9.5", MtProductSerializer.serialize(product)[:price]
  end

  def test_json_fields_round_trip_on_every_adapter
    db.create_table!(:mt_documents) do
      primary_key :id
      column :data, :jsonb, null: false
    end
    document_class = Class.new(GemStack::Model(:mt_documents)) { field :data, :json, null: false }
    document = document_class.create(data: { "tags" => ["a"], "n" => 1 })

    assert_equal({ "tags" => ["a"], "n" => 1 }, document_class[document.id].data.to_h)
  ensure
    db.drop_table?(:mt_documents)
  end

  def test_transactions
    GemStack.transaction do
      MtProduct.create(name: "Lamp", price: 1)
      raise Sequel::Rollback
    end

    assert_equal 0, MtProduct.count
  end
end

# Transactions wrap #run, which executes before setup could skip.
if DBTest.available?
  class TransactionalTestsTest < Minitest::Test
    include DBTest
    include GemStack::DB::Testing::Transactions

    # Both orders must see an empty table: each test's insert is rolled back.
    def test_first = assert_isolated
    def test_second = assert_isolated

    def assert_isolated
      assert_equal 0, MtCategory.where(name: "Tx").count
      MtCategory.create(name: "Tx")
      GemStack.transaction { MtCategory.create(name: "Nested") } # savepoint

      assert_equal 1, MtCategory.where(name: "Tx").count
    end
  end
end
