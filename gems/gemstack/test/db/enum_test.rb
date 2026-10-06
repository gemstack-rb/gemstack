# frozen_string_literal: true

require "test_helper"

module EnumFixtures
  def self.install!
    return if @installed

    db = GemStack::DB.connection
    db.drop_table?(:en_posts)
    db.create_table(:en_posts) do
      primary_key :id, type: :Bignum
      String :title, null: false
      String :status, size: 50, null: false, default: "draft"
      String :visibility, size: 50
      String :kind, size: 50
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
    end
    Object.const_set(:EnPost, Class.new(GemStack::Model(:en_posts)) do
      field :title, :string, null: false
      enum :status, %w[draft published archived], default: "draft"
      enum :visibility, %i[public private], null: true, prefix: true
      enum :kind, %w[new old], null: true, prefix: "is", scopes: false
    end)
    @installed = true
  end
end

EnumFixtures.install! if DBTest.available?

class EnumTest < Minitest::Test
  include DBTest

  def setup
    super
    db[:en_posts].delete
  end

  def test_values_and_default
    post = EnPost.new(title: "Hi")

    assert_equal %w[draft published archived], EnPost.statuses
    assert_equal "draft", post.status
    assert_predicate post, :draft?
    refute_predicate post, :published?
    assert_equal "published", EnPost.new(title: "x", status: "published").status
  end

  def test_bang_methods_and_scopes
    post = EnPost.create(title: "Hi")
    EnPost.create(title: "Old", status: "archived")
    post.published!

    assert_equal "published", post.reload.status
    assert_equal ["Hi"], EnPost.published.select_map(:title)
    assert_equal ["Old"], EnPost.where(title: "Old").archived.select_map(:title), "chainable"
    assert_equal 0, EnPost.draft.count
  end

  def test_validation
    post = EnPost.new(title: "Hi", status: "lost", visibility: "secret")

    refute_predicate post, :valid?
    assert_equal({ status: ["must be one of: draft, published, archived"],
                   visibility: ["must be one of: public, private"] }, post.errors.to_h)
    assert_predicate EnPost.new(title: "Hi", visibility: nil), :valid?, "null: true"
    error = assert_raises(Sequel::ValidationFailed) { EnPost.create(title: "Hi", status: "lost") }

    assert_equal "Validation failed: status must be one of: draft, published, archived",
                 GemStack::ErrorMapping.translate(error).message
  end

  def test_symbols_are_stored_as_strings
    assert_equal "published", EnPost.create(title: "Hi", status: :published).reload.status
  end

  def test_prefixes
    post = EnPost.new(title: "Hi", visibility: "private", kind: "new")

    assert_predicate post, :visibility_private?
    assert_predicate post, :is_new?
    assert_equal 0, EnPost.visibility_public.count
    refute_respond_to EnPost, :is_new, "scopes: false"
  end

  def test_input_schema_and_samples
    schema = EnPost.input_schema

    assert_equal({ title: "x" }, schema.call("title" => "x"), "optional: the model fills in the default")
    assert_raises(GemStack::ValidationError) { schema.call("title" => "x", "status" => "lost") }
    assert_equal "draft", GemStack::DB::Testing.sample_attributes(EnPost)[:status]
  end

  def test_declaration_errors
    model = Class.new(GemStack::Model(:en_posts))

    assert_raises(ArgumentError) { model.enum :kind, %w[new old] } # EnPost.new would be replaced
    assert_raises(ArgumentError) { model.enum :status, %w[a b], default: "c" }
    assert_raises(ArgumentError) { model.enum :status, [] }
    model.enum :status, %w[draft published]

    error = assert_raises(ArgumentError) { model.enum :visibility, %w[draft] } # draft? taken

    assert_match(/prefix/, error.message)
  end
end
