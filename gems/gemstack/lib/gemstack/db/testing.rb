# frozen_string_literal: true

require "gemstack/db"
require "securerandom"

module GemStack
  module DB
    # Test support, used by the generated test/test_helper.rb:
    #
    #   require "gemstack/db/testing"
    #   GemStack::DB::Testing.prepare!             # create + migrate the test database
    #   GemStack::TestCase.include GemStack::DB::Testing::Transactions
    module Testing
      module_function

      # Creates the test database if needed and applies pending migrations,
      # so `gemstack test` works on a fresh checkout.
      def prepare!
        Tasks.create
        Migrator.new.migrate
      end

      # Valid attribute values for a model, derived from its `field`
      # declarations (types, size, gt/gte/lt/lte, in:). Unique-looking values
      # use a sequence; `references` fields create the referenced record.
      # Fields with a `format:` rule may need an override.
      #
      #   Product.create(GemStack::DB::Testing.sample_attributes(Product, name: "Lamp"))
      def sample_attributes(model, overrides = {})
        @sequence = (@sequence || 0) + 1
        model.gemstack_fields.each_value.with_object({}) do |field, attrs|
          attrs[field.name] = sample_value(model, field, @sequence)
        end.merge(overrides)
      end

      # sample_attributes as JSON-ready values (for request bodies).
      def sample_payload(model, overrides = {})
        sample_attributes(model, overrides).transform_values do |value|
          case value
          when BigDecimal then value.to_s("F")
          when Time then value.utc.iso8601
          when Date then value.iso8601
          else value
          end
        end
      end

      def sample_value(model, field, sequence)
        opts = field.options
        return Array(opts[:in]).first if opts[:in]

        case field.type
        when :string, :text then sample_string(field, opts, sequence)
        when :integer, :bigint then bounded(opts, 1, step: 1).to_i
        when :float then bounded(opts, 1.5, step: 1).to_f
        when :decimal then BigDecimal(bounded(opts, BigDecimal("9.99"), step: 1).to_s)
        when :boolean then true
        when :date then Date.today
        when :datetime then Time.now.utc.round
        when :uuid then SecureRandom.uuid
        when :json then { "sample" => true }
        when :references then sample_reference(model, field)
        end
      end

      def sample_string(field, opts, sequence)
        value = "#{Inflector.humanize(field.name)} #{sequence}"
        opts[:size].is_a?(Integer) ? value[0, opts[:size]] : value
      end

      def bounded(opts, value, step:)
        value = opts[:gt] + step if opts[:gt] && value <= opts[:gt]
        value = opts[:gte] if opts[:gte] && value < opts[:gte]
        value = opts[:lt] - step if opts[:lt] && value >= opts[:lt]
        value = opts[:lte] if opts[:lte] && value > opts[:lte]
        value
      end

      def sample_reference(model, field)
        reflection = model.association_reflections.values.find { |r| r[:key] == field.name }
        target = reflection&.associated_class ||
                 Object.const_get(Inflector.camelize(field.name.to_s.delete_suffix("_id")))
        target.create(sample_attributes(target)).pk
      end

      # Runs every test inside a transaction that is rolled back afterwards.
      # Requests made through rack-test run on the same thread, so they see
      # (and roll back) the same data. Nested GemStack.transaction calls
      # become savepoints.
      module Transactions
        def run(...)
          result = nil
          DB.connection.transaction(rollback: :always, auto_savepoint: true) { result = super }
          result
        end
      end
    end
  end
end
