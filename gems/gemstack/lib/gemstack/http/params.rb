# frozen_string_literal: true

module GemStack
  module HTTP
    # Request parameters with indifferent (string/symbol) key access and
    # explicit allow-listing for anything that reaches the application:
    #
    #   params[:id]                              # path, query or body
    #   params.require(:product)                 # 400 if missing/blank
    #   params.permit(:name, :price, tags: [], dimensions: [:width, :height])
    #   # => { name: "Lamp", price: "9.99", tags: ["home"], dimensions: { width: 3, height: 5 } }
    #
    # #permit only returns scalars (and arrays/hashes that are explicitly
    # declared), so unexpected nested structures never reach models.
    class Params
      include Enumerable

      class ParameterMissing < BadRequest
        def initialize(key)
          super("Missing parameter: #{key}", code: "parameter_missing", details: { key.to_s => ["is required"] })
        end
      end

      SCALARS = [String, Integer, Float, TrueClass, FalseClass, NilClass].freeze

      def initialize(hash = {})
        @hash = hash.transform_keys(&:to_s)
      end

      def [](key) = wrap(@hash[key.to_s])
      def key?(key) = @hash.key?(key.to_s)
      alias has_key? key?
      alias include? key?
      def keys = @hash.keys
      def empty? = @hash.empty?
      def size = @hash.size
      def each(&) = @hash.each { |key, value| yield key, wrap(value) }

      def fetch(key, *default, &)
        wrap(@hash.fetch(key.to_s, *default, &))
      end

      def dig(key, *rest)
        value = self[key]
        rest.empty? || value.nil? ? value : value.dig(*rest)
      end

      # Returns the value for key, raising ParameterMissing (400) when it is
      # absent, nil, or an empty string/collection.
      def require(key)
        value = @hash[key.to_s]
        raise ParameterMissing, key if blank?(value)

        wrap(value)
      end

      def slice(*keys) = Params.new(@hash.slice(*keys.map(&:to_s)))
      def except(*keys) = Params.new(@hash.except(*keys.map(&:to_s)))

      # Allow-list. Returns a plain Hash with symbol keys.
      def permit(*filters)
        filters.each_with_object({}) do |filter, result|
          case filter
          when Symbol, String
            key = filter.to_s
            value = @hash[key]
            result[filter.to_sym] = value if @hash.key?(key) && scalar?(value)
          when Hash
            filter.each { |key, nested| permit_nested(result, key, nested) }
          else
            raise ArgumentError, "invalid permit filter #{filter.inspect}"
          end
        end
      end

      # Validates and coerces against a schema (see GemStack::Schema), returning
      # a symbol-keyed Hash of declared fields or raising a 422 ValidationError:
      #
      #   attrs = params.validate do
      #     required :name, :string
      #     required :price, :decimal, gt: 0
      #   end
      #   attrs = params.validate(ProductInput)
      def validate(schema = nil, &)
        schema ||= Schema.define(&)
        schema.call(@hash)
      end

      # Unfiltered, deep copy with string keys. Prefer #permit for input
      # that will be persisted.
      def to_h = deep_dup(@hash)
      alias to_unsafe_h to_h

      def ==(other)
        to_h == (other.is_a?(Params) ? other.to_h : other)
      end

      def inspect = "#<#{self.class.name} #{@hash.inspect}>"

      private

      def permit_nested(result, key, nested)
        value = @hash[key.to_s]
        return unless @hash.key?(key.to_s)

        if nested == [] # array of scalars
          result[key.to_sym] = value.select { |v| scalar?(v) } if value.is_a?(Array)
        elsif value.is_a?(Hash)
          result[key.to_sym] = Params.new(value).permit(*nested)
        elsif value.is_a?(Array) && value.all?(Hash) # array of objects
          result[key.to_sym] = value.map { |item| Params.new(item).permit(*nested) }
        end
      end

      def wrap(value)
        case value
        when Hash then Params.new(value)
        when Array then value.map { |v| wrap(v) }
        else value
        end
      end

      def scalar?(value) = SCALARS.any? { |type| value.is_a?(type) } || uploaded_file?(value)

      def uploaded_file?(value) = defined?(Rack::Multipart::UploadedFile) && value.is_a?(Rack::Multipart::UploadedFile)

      def blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?) || (value.is_a?(String) && value.strip.empty?)
      end

      def deep_dup(value)
        case value
        when Hash then value.transform_values { |v| deep_dup(v) }
        when Array then value.map { |v| deep_dup(v) }
        else value
        end
      end
    end
  end
end
