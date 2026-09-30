# frozen_string_literal: true

require "gemstack/core"
require_relative "types"

module GemStack
  # Declarative input validation and coercion.
  #
  #   class ProductInput < GemStack::Schema
  #     required :name, :string, max_length: 120
  #     required :price, :decimal, gt: 0
  #     optional :active, :boolean, default: true
  #     optional :tags, [:string]
  #     optional :dimensions do
  #       required :width, :integer
  #     end
  #   end
  #
  #   ProductInput.call(params)   # => { name: "Lamp", price: 0.999e1, active: true }
  #                               # or raises GemStack::ValidationError (422) with
  #                               #    errors: { "price" => ["must be greater than 0"] }
  #
  # - Output has symbol keys and only declared fields (an allow-list).
  # - Values are coerced to their type ("12" → 12 for :integer).
  # - For non-string types an empty string counts as "not given" (HTML forms).
  # - A required string that is blank is reported as "is required".
  # - Error keys are paths: "dimensions.width", "tags.2".
  class Schema
    Field = Struct.new(:name, :type, :required, :nullable, :default, :rules, :schema, :array, keyword_init: true) do
      def default? = !default.equal?(NO_DEFAULT)
      def default_value = default.respond_to?(:call) ? default.call : default
      def ts_optional? = !required && !default?
    end

    NO_DEFAULT = Object.new.freeze
    RULES = %i[gt gte lt lte min_length max_length in format].freeze
    STRING_TYPES = %i[string text].freeze

    # rule => [passes?(value, arg), message(arg)]
    RULE_CHECKS = {
      gt: [->(v, a) { v > a }, ->(a) { "must be greater than #{a}" }],
      gte: [->(v, a) { v >= a }, ->(a) { "must be greater than or equal to #{a}" }],
      lt: [->(v, a) { v < a }, ->(a) { "must be less than #{a}" }],
      lte: [->(v, a) { v <= a }, ->(a) { "must be less than or equal to #{a}" }],
      min_length: [->(v, a) { v.to_s.length >= a }, ->(a) { "is too short (minimum #{a} characters)" }],
      max_length: [->(v, a) { v.to_s.length <= a }, ->(a) { "is too long (maximum #{a} characters)" }],
      in: [->(v, a) { a.include?(v) }, ->(a) { "must be one of: #{a.to_a.join(", ")}" }],
      format: [->(v, a) { a.match?(v.to_s) }, ->(_) { "is invalid" }]
    }.freeze

    class << self
      def fields
        @fields ||= superclass.respond_to?(:fields) ? superclass.fields.dup : {}
      end

      # Name used for this schema's TypeScript/OpenAPI type.
      attr_writer :type_name

      def type_name
        @type_name || name&.split("::")&.join
      end

      def required(name, type = nil, **options, &) = add_field(name, type, true, options, &)
      def optional(name, type = nil, **options, &) = add_field(name, type, false, options, &)

      # An anonymous schema from a block: Schema.define { required :q, :string }
      def define(type_name = nil, &)
        Class.new(self) do
          self.type_name = type_name
          class_exec(&)
        end
      end

      # Every field optional and without defaults — for PATCH-style updates.
      def partial(type_name = nil)
        source = self
        Class.new(Schema) do
          self.type_name = type_name
          source.fields.each_value do |field|
            fields[field.name] = field.dup.tap do |copy|
              copy.required = false
              copy.default = NO_DEFAULT
            end
          end
        end
      end

      # A schema derived from a model's field declarations (anything that
      # responds to #gemstack_fields → { name => field with #type and #options }).
      # Fields that are NOT NULL without a default become required.
      def from_model(model, only: nil, except: nil, type_name: nil)
        declared = model.gemstack_fields
        names = only ? Array(only).map(&:to_sym) : declared.keys
        names -= Array(except).map(&:to_sym)
        define(type_name) do
          names.each do |name|
            field = declared.fetch(name) { raise ArgumentError, "#{model} has no field #{name.inspect}" }
            opts = field.options
            rules = opts.slice(*RULES)
            rules[:max_length] ||= opts[:size] if opts[:size].is_a?(Integer)
            required = opts[:null] == false && !opts.key?(:default) && field.type != :boolean
            add_field(name, field.type, required, rules.merge(nullable: opts[:null] != false))
          end
        end
      end

      def call(input)
        errors = {}
        result = coerce_object(input, nil, errors)
        raise ValidationError.new(errors: errors) unless errors.empty?

        result
      end

      # Like #call but returns [result, errors] instead of raising.
      def validate(input)
        errors = {}
        result = coerce_object(input, nil, errors)
        [errors.empty? ? result : nil, errors]
      end

      def coerce_object(input, path, errors)
        input = normalize_input(input)
        unless input.is_a?(Hash)
          errors[path || "base"] = ["must be an object"]
          return nil
        end

        fields.each_value.with_object({}) do |field, output|
          coerce_field(field, input, path, output, errors)
        end
      end

      private

      def add_field(name, type, required, options, &block)
        options = options.dup
        nullable = options.delete(:nullable) || false
        default = options.key?(:default) ? options.delete(:default) : NO_DEFAULT
        unknown = options.keys - RULES
        raise ArgumentError, "unknown option(s) #{unknown.inspect} for #{name}" unless unknown.empty?

        array = false
        schema = nil
        if type.is_a?(Array)
          array = true
          type = type.first
        elsif type == :array
          array = true
          type = nil
        end
        if block
          schema = Schema.define(&block)
          type = nil
        elsif type.is_a?(Class) && type <= Schema
          schema = type
          type = nil
        elsif type.nil?
          raise ArgumentError, "#{name}: give a type (e.g. :string) or a block"
        else
          Types.fetch(type) # validate early
          type = Types::CLASS_ALIASES.fetch(type, type).to_sym
        end

        fields[name.to_sym] = Field.new(name: name.to_sym, type: type, required: required, nullable: nullable,
                                        default: default, rules: options.freeze, schema: schema, array: array)
      end

      # absent → default or omitted; required + absent/nil/blank → "is required";
      # explicit null → nil when nullable, otherwise "can't be null".
      def coerce_field(field, input, path, output, errors)
        key = field.name.to_s
        field_path = path ? "#{path}.#{key}" : key
        value = input[key]
        present = input.key?(key) && !empty_form_value?(field, value)

        if field.required && (!present || value.nil? || blank_string?(value))
          missing_required(field, present, field_path, output, errors)
        elsif !present
          output[field.name] = field.default_value if field.default?
        else
          coerce_present(field, value, field_path, output, errors)
        end
      end

      def coerce_present(field, value, path, output, errors)
        if value.nil?
          field.nullable ? output[field.name] = nil : (errors[path] ||= []) << "can't be null"
        else
          coerced = coerce_value(field, value, path, errors)
          output[field.name] = coerced unless coerced.equal?(NO_DEFAULT)
        end
      end

      def missing_required(field, present, path, output, errors)
        return output[field.name] = field.default_value if field.default? && !present

        (errors[path] ||= []) << "is required"
      end

      def coerce_value(field, value, path, errors)
        return coerce_array(field, value, path, errors) if field.array

        coerce_single(field, value, path, errors)
      end

      def coerce_array(field, value, path, errors)
        value = value.values if value.is_a?(Hash) && value.keys.all? { |k| k.to_s.match?(/\A\d+\z/) } # form arrays
        unless value.is_a?(Array)
          (errors[path] ||= []) << "must be a list"
          return NO_DEFAULT
        end

        value.each_with_index.map { |item, index| coerce_single(field, item, "#{path}.#{index}", errors) }
      end

      def coerce_single(field, value, path, errors)
        return field.schema.coerce_object(value, path, errors) if field.schema

        coerced = Types.fetch(field.type).coerce(value)
        check_rules(field.rules, coerced, path, errors)
        coerced
      rescue Types::CoercionError => e
        (errors[path] ||= []) << e.message
        NO_DEFAULT
      end

      def check_rules(rules, value, path, errors)
        messages = rules.filter_map { |rule, arg| rule_message(rule, arg, value) }
        (errors[path] ||= []).concat(messages) unless messages.empty?
      end

      def rule_message(rule, arg, value)
        check, message = RULE_CHECKS.fetch(rule)
        check.call(value, arg) ? nil : message.call(arg)
      end

      def normalize_input(input)
        input = input.to_unsafe_h if input.respond_to?(:to_unsafe_h) # GemStack::Params
        input.is_a?(Hash) ? input.transform_keys(&:to_s) : input
      end

      def blank_string?(value) = value.is_a?(String) && value.strip.empty?

      # An empty form input for a non-string field means "not given".
      def empty_form_value?(field, value) = value == "" && !STRING_TYPES.include?(field.type)
    end
  end
end

require_relative "serializer"
