# frozen_string_literal: true

module GemStack
  # Explicit, typed JSON representations. Nothing is exposed unless listed.
  #
  #   class ProductSerializer < GemStack::Serializer
  #     attributes :id, :name, :price, :active, :created_at   # types inferred from Product's fields
  #     attribute :display_price, :string do |product|
  #       "€#{product.price}"
  #     end
  #     attribute :category, CategorySerializer                 # nested
  #     attribute :reviews, [ReviewSerializer]                  # nested list
  #   end
  #
  #   ProductSerializer.serialize(product)   # => { id: 1, name: "Lamp", price: "9.99", ... }
  #   ProductSerializer.many(products)       # => [ {...}, ... ]
  #
  # Values are dumped by type: decimals become strings, times ISO 8601 UTC.
  # Types come from an explicit type argument, else from the model's field
  # declarations (the model is found by name: ProductSerializer → Product),
  # and drive the generated TypeScript interfaces.
  class Serializer
    Attribute = Struct.new(:name, :type, :block, :nullable, keyword_init: true) do
      def serializer? = type.is_a?(Class) && type <= Serializer
      def list? = type.is_a?(Array)
    end

    CONVENTIONAL_TYPES = { id: [:bigint, false], created_at: [:datetime, false], updated_at: [:datetime, false] }.freeze

    class << self
      def attributes_list
        @attributes_list ||= superclass.respond_to?(:attributes_list) ? superclass.attributes_list.dup : {}
      end

      # attributes :id, :name        (types inferred)
      # attributes name: :string     (explicit)
      def attributes(*names, **typed)
        names.each { |name| attribute(name) }
        typed.each { |name, type| attribute(name, type) }
      end

      def attribute(name, type = nil, nullable: nil, &block)
        if type && !type.is_a?(Array) && !(type.is_a?(Class) && type <= Serializer)
          type = Types::CLASS_ALIASES.fetch(type, type).to_sym
          Types.fetch(type)
        end
        attributes_list[name.to_sym] = Attribute.new(name: name.to_sym, type: type, block: block, nullable: nullable)
        @resolved_attributes = nil
      end

      # The model used for type inference. Defaults to the class named like
      # the serializer without "Serializer" (Admin::ProductSerializer → Admin::Product, then Product).
      def model(klass = nil)
        @model = klass if klass
        return @model if defined?(@model) && @model

        base = name&.delete_suffix("Serializer")
        return nil if base.nil? || base.empty?

        [base, base.split("::").last].uniq.each do |candidate|
          constant = Object.const_get(candidate) if Object.const_defined?(candidate)
          return constant if constant.respond_to?(:gemstack_fields)
        rescue NameError
          next
        end
        nil
      end

      attr_writer :type_name

      # TypeScript/OpenAPI name: ProductSerializer → "Product", Admin::ProductSerializer → "AdminProduct".
      def type_name
        @type_name || (name && name.delete_suffix("Serializer").split("::").join)
      end

      # Attributes with resolved types: [{name:, type:, nullable:}], type being
      # a type Symbol, a Serializer class, or [Serializer]/[:type] for lists.
      def resolved_attributes
        @resolved_attributes ||= attributes_list.values.map do |attr|
          type, nullable = infer(attr)
          { name: attr.name, type: type, nullable: attr.nullable.nil? ? nullable : attr.nullable }
        end.freeze
      end

      # [[name, block_or_nil, dumper_or_nil], ...] — types resolved to
      # dumpers once, so serializing an object does no type lookups.
      def compiled
        @compiled ||= resolved_attributes.map do |attr|
          [attr[:name], attributes_list[attr[:name]].block, dumper_for(attr[:type])]
        end.freeze
      end

      def serialize(object, context = {})
        object.nil? ? nil : new(object, context).to_h
      end

      def many(objects, context = {})
        objects = objects.all if objects.respond_to?(:all) && !objects.is_a?(Array) # Sequel datasets
        objects.map { |object| new(object, context).to_h }
      end

      # Convention-based rendering, shared by controllers (`render`) and
      # realtime (`GemStack.broadcast`): an object of class Product uses
      # ProductSerializer, arrays and datasets of them too; plain JSON values
      # and objects without a serializer pass through unchanged.
      def render(value, context = {})
        case value
        when Hash, String, Numeric, Symbol, true, false, nil then value
        when Array
          serializer = value.first && self.for(value.first.class)
          serializer ? serializer.many(value, context) : value
        else
          if value.respond_to?(:model) && value.respond_to?(:all) # a dataset / query
            serializer = self.for(value.model)
            return serializer ? serializer.many(value, context) : value.all
          end
          serializer = self.for(value.class)
          serializer ? serializer.serialize(value, context) : value
        end
      end

      # Defaults for convention-based lookup: ProductSerializer for Product.
      def for(object_class)
        return nil unless object_class.name

        name = "#{object_class.name}Serializer"
        Object.const_defined?(name) ? Object.const_get(name) : nil
      rescue NameError
        nil
      end

      private

      # A lambda (value, context) -> JSON value, or nil when values pass through.
      def dumper_for(type)
        case type
        when Array
          item = dumper_for(type.first)
          return nil unless item

          ->(values, ctx) { values.map { |v| v.nil? ? nil : item.call(v, ctx) } }
        when Symbol then scalar_dumper(Types.fetch(type))
        else ->(value, ctx) { type.serialize(value, ctx) } # nested serializer
        end
      end

      def scalar_dumper(type)
        if %i[string text].include?(type.name)
          ->(value, _) { value.is_a?(String) ? value : type.coerce(value) }
        elsif type.dumper
          dump = type.dumper
          ->(value, _) { dump.call(value) }
        end
      end

      # Explicit types are non-null unless declared nullable or the model's
      # field allows null; inferred types follow the model's field.
      def infer(attr)
        field = model&.gemstack_fields&.[](attr.name)
        return [attr.type, field ? field.options[:null] != false : false] if attr.type
        return [field.type, field.options[:null] != false] if field

        CONVENTIONAL_TYPES.fetch(attr.name) { [:json, true] }
      end
    end

    attr_reader :object, :context

    def initialize(object, context = {})
      @object = object
      @context = context
    end

    # Hot path: iterates the plan compiled once per serializer class
    # (docs/performance.md — this loop dominates JSON response time).
    def to_h
      hash = {}
      self.class.compiled.each do |name, block, dumper|
        value = block ? instance_exec(object, &block) : object.public_send(name)
        hash[name] = value.nil? || dumper.nil? ? value : dumper.call(value, context)
      end
      hash
    end
    alias as_json to_h
  end
end
