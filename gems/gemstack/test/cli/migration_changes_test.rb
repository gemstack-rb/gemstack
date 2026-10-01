# frozen_string_literal: true

require "test_helper"

class MigrationChangesTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("gemstack-migration-changes")
    @output = StringIO.new
  end

  def teardown = FileUtils.remove_entry(@root)

  def generate(fields)
    spec = GemStack::CLI::ResourceSpec.new("Product", fields)
    GemStack::CLI::ResourceGenerator.new(spec, root: @root, parts: [:migration], output: @output).run
  end

  def migration = Dir["#{@root}/db/migrations/*_create_products.rb"].first

  def test_new_field_prints_an_executable_migration_command_without_rewriting_history
    generate(%w[name:string])
    original = File.binread(migration)
    generate(%w[name:string price:decimal])
    assert_includes @output.string, "gemstack g migration AddPriceToProducts price:decimal"
    assert_equal original, File.binread(migration)
    assert_equal 1, Dir["#{@root}/db/migrations/*.rb"].size
  end

  def test_unchanged_fields_of_every_supported_type_need_no_schema_change
    fields = %w[name:string body:text count:integer large:bigint weight:float price:decimal active:boolean
                released:date published:datetime token:uuid data:json category:references sku:string:unique
                optional:string:optional indexed:integer:index]
    generate(fields)
    generate(fields)
    refute_includes @output.string, "New column"
    refute_includes @output.string, "Changed column"
    refute_includes @output.string, "Cannot safely compare"
  end

  def test_changed_type_nullability_and_index_have_manual_alter_commands
    generate(%w[name:string price:integer sku:string:index])
    generate(%w[name:string:optional price:decimal sku:string:unique])
    %w[Name Price Sku].each do |name|
      assert_includes @output.string, "gemstack g migration Change#{name}OnProducts"
      refute_includes @output.string, "gemstack g migration Add#{name}ToProducts"
    end
    assert_includes @output.string, "Edit its empty change block"
    assert_includes @output.string, "do not add the column again"
  end

  def test_add_commands_preserve_modifiers_and_reference_names
    generate(%w[name:string])
    generate(%w[name:string sku:string:optional:unique count:integer:index category_id:references:optional])
    assert_includes @output.string, "AddSkuToProducts sku:string:optional:unique"
    assert_includes @output.string, "AddCountToProducts count:integer:index"
    assert_includes @output.string, "AddCategoryToProducts category:references:optional"
  end

  def test_comments_formatting_and_option_order_do_not_change_comparison
    generate(%w[name:string:unique])
    File.write(migration, File.read(migration).sub("String :name, null: false, unique: true",
                                                   "String(:name, unique: true,\n null: false) # comment"))
    generate(%w[name:string:unique])
    refute_includes @output.string, "Changed column"
    refute_includes @output.string, "Cannot safely compare"
  end

  def test_custom_migration_is_not_executed_and_gets_manual_guidance
    generate(%w[name:string])
    File.write(migration, "raise 'must not execute migration'\n")
    generate(%w[name:string price:decimal])
    assert_includes @output.string, "Cannot safely compare"
    assert_includes @output.string, "gemstack g migration UpdateProductsSchema"
    refute_includes @output.string, "AddPriceToProducts"
  end

  def test_invalid_ruby_gets_manual_guidance
    generate(%w[name:string])
    File.write(migration, "Sequel.migration do\n")
    generate(%w[name:string price:decimal])
    assert_includes @output.string, "Cannot safely compare"
  end

  def test_later_alter_migration_prevents_duplicate_add_advice
    generate(%w[name:string])
    GemStack::CLI::MigrationGenerator.new("AddPriceToProducts", ["price:decimal"],
                                          root: @root, output: @output).run
    @output.truncate(0)
    @output.rewind
    generate(%w[name:string price:decimal])
    assert_includes @output.string, "custom schema or later migrations"
    refute_includes @output.string, "gemstack g migration AddPriceToProducts"
  end

  def test_unrelated_later_migration_does_not_prevent_comparison
    generate(%w[name:string])
    GemStack::CLI::MigrationGenerator.new("AddTitleToPosts", ["title:string"],
                                          root: @root, output: @output).run
    generate(%w[name:string price:decimal])
    assert_includes @output.string, "gemstack g migration AddPriceToProducts price:decimal"
  end

  def test_multiple_create_migrations_require_manual_review
    generate(%w[name:string])
    FileUtils.cp(migration, "#{@root}/db/migrations/99999999999999_create_products.rb")
    generate(%w[name:string price:decimal])
    assert_includes @output.string, "Cannot safely compare"
  end
end
