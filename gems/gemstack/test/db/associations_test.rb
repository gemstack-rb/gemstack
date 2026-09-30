# frozen_string_literal: true

require "test_helper"

# What docs/models.md → "Associations and eager loading" promises.
class AssociationsTest < Minitest::Test
  include DBTest

  module Fixtures
    def self.install!
      return if @installed

      db = GemStack::DB.connection
      db.drop_table?(:at_products_tags, :at_reviews, :at_tags, :at_products, :at_categories,
                     cascade: GemStack::DB.postgres?)
      db.create_table(:at_categories) do
        primary_key :id
        String :name, null: false
      end
      db.create_table(:at_products) do
        primary_key :id
        foreign_key :category_id, :at_categories
        String :name, null: false
      end
      db.create_table(:at_reviews) do
        primary_key :id
        foreign_key :product_id, :at_products
        Integer :stars, null: false
      end
      db.create_table(:at_tags) do
        primary_key :id
        String :name, null: false
      end
      db.create_table(:at_products_tags) do
        foreign_key :product_id, :at_products
        foreign_key :tag_id, :at_tags
      end

      Object.const_set(:AtCategory, Class.new(GemStack::Model(:at_categories)))
      Object.const_set(:AtProduct, Class.new(GemStack::Model(:at_products)))
      Object.const_set(:AtReview, Class.new(GemStack::Model(:at_reviews)))
      Object.const_set(:AtTag, Class.new(GemStack::Model(:at_tags)))
      AtProduct.belongs_to :category, class: "AtCategory"
      AtProduct.has_many :reviews, class: "AtReview", key: :product_id
      AtProduct.many_to_many :tags, class: "AtTag", join_table: :at_products_tags,
                                    left_key: :product_id, right_key: :tag_id
      @installed = true
    end
  end

  def setup
    super
    Fixtures.install!
    db[:at_products_tags].delete
    [AtReview, AtTag, AtProduct, AtCategory].each { |model| model.dataset.delete }
    lamps = AtCategory.create(name: "Lamps")
    chairs = AtCategory.create(name: "Chairs")
    sale = AtTag.create(name: "sale")
    6.times do |i|
      product = AtProduct.create(name: "P#{i}", category_id: (i.even? ? lamps : chairs).id)
      [4, 5].each { |stars| AtReview.create(product_id: product.id, stars: stars) }
      product.add_tag(sale) if i.even?
    end
  end

  # The SELECTs run inside the block.
  def selects
    queries = []
    logger = Object.new
    %i[debug info warn error].each do |level|
      logger.define_singleton_method(level) { |message = nil| queries << message if message.to_s.include?("SELECT") }
    end
    db.loggers << logger
    yield
    queries
  ensure
    db.loggers.delete(logger)
  end

  def test_eager_loads_each_association_with_one_query
    products = nil
    queries = selects { products = AtProduct.eager(:category, :reviews, :tags).order(:id).all }

    assert_equal 4, queries.size
    assert_equal 0, selects { products.each { |p| [p.category.name, p.reviews.size, p.tags.size] } }.size
    assert_equal %w[Lamps Chairs], products.map { |p| p.category.name }.uniq
    assert_equal([2] * 6, products.map { |p| p.reviews.size })
    assert_equal(3, products.count { |p| p.tags.any? })
  end

  def test_lazy_loading_in_a_loop_is_n_plus_one
    assert_equal 7, selects { AtProduct.all.each(&:category) }.size
  end

  def test_eager_graph_loads_with_a_single_join
    products = nil
    queries = selects do
      products = AtProduct.eager_graph(:category).where(Sequel[:category][:name] => "Lamps").all
    end

    assert_equal 1, queries.size
    assert_equal %w[P0 P2 P4], products.map(&:name).sort
    assert_empty(selects { products.each(&:category) })
  end

  def test_association_join_filters_on_the_joined_table
    products = AtProduct.association_join(:category).where(Sequel[:category][:name] => "Chairs")
                        .select_all(:at_products).all

    assert_equal %w[P1 P3 P5], products.map(&:name).sort
    assert_equal 3, AtProduct.where(category: AtCategory.first(name: "Lamps")).count
  end

  def test_eager_keeps_limit_and_count_right_but_eager_graph_on_has_many_does_not
    assert_equal 6, AtProduct.eager(:reviews).count
    assert_equal 2, AtProduct.eager(:reviews).order(:id).limit(2).all.size
    # The pitfall the docs warn about: one row per review.
    assert_equal 12, AtProduct.eager_graph(:reviews).count
    assert_operator AtProduct.eager_graph(:reviews).limit(2).all.size, :<, 2
  end

  def test_tactical_eager_loading_turns_n_plus_one_into_one_query
    model = Class.new(AtProduct) { plugin :tactical_eager_loading }

    assert_equal 2, selects { model.all.each(&:category) }.size
  end

  def test_forbid_lazy_load_raises_in_a_loop_but_not_for_a_single_record
    model = Class.new(AtProduct) { plugin :forbid_lazy_load }

    assert_raises(Sequel::Plugins::ForbidLazyLoad::Error) { model.all.each(&:category) }
    assert_equal "Lamps", model.first(name: "P0").category.name
    assert_equal(6, model.eager(:category).all.count { |p| p.category.name })
  end
end
