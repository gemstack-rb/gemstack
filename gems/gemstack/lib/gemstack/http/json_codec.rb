# frozen_string_literal: true

require "json"
require "time"
require "date"

module GemStack
  module HTTP
    # JSON encoding/decoding behind a two-method interface (dump / load), so the
    # implementation can be swapped with `config.http.json = :oj | codec`.
    module JSONCodec
      # How non-JSON-native Ruby objects are encoded. Objects must opt in by
      # defining #as_json (or #to_h); anything else raises instead of silently
      # leaking #inspect/#to_s output into API responses.
      def self.coerce(object)
        case object
        when Symbol then object.name
        when Time, DateTime then object.iso8601(3)
        when Date then object.iso8601
        when Set then object.to_a
        else
          if object.respond_to?(:as_json) then object.as_json
          elsif defined?(BigDecimal) && object.is_a?(BigDecimal) then object.to_s("F")
          elsif object.respond_to?(:to_h) then object.to_h
          else
            raise TypeError, "#{object.class} is not JSON serializable; define #as_json or use a serializer"
          end
        end
      end

      # Default codec, backed by the json gem's JSON::Coder: native types are
      # encoded in C and the coerce block only runs for other objects.
      class Stdlib
        def initialize(max_nesting: 64)
          @max_nesting = max_nesting
          @coder = ::JSON::Coder.new { |object| JSONCodec.coerce(object) }
        end

        def dump(object) = @coder.dump(object)

        def load(source)
          ::JSON.parse(source, max_nesting: @max_nesting)
        end
      end

      class Oj
        def initialize(max_nesting: 64)
          require "oj"
          @max_nesting = max_nesting
        end

        # Serializer output is already JSON-native, so try Oj's C strict mode
        # first; only values with Time, BigDecimal, models... take the slower
        # normalising path.
        def dump(object)
          ::Oj.dump(object, mode: :strict)
        rescue TypeError, EncodingError
          ::Oj.dump(normalize(object), mode: :strict)
        end

        def load(source)
          # Oj has no depth limit option in strict mode; enforce it with the
          # stdlib parser's semantics by checking depth after parsing.
          result = ::Oj.load(source, mode: :strict)
          raise ::JSON::NestingError, "nesting too deep" if depth(result) > @max_nesting

          result
        rescue ::Oj::ParseError, EncodingError => e
          raise ::JSON::ParserError, e.message
        end

        private

        def normalize(object)
          case object
          when Hash then object.to_h { |k, v| [k.is_a?(Symbol) ? k.name : k, normalize(v)] }
          when Array then object.map { |v| normalize(v) }
          when String, Integer, Float, true, false, nil then object
          else normalize(JSONCodec.coerce(object))
          end
        end

        # Same definition as the json gem: `{}` and `[]` have depth 1.
        def depth(object)
          case object
          when Hash then 1 + (object.each_value.map { |v| depth(v) }.max || 0)
          when Array then 1 + (object.map { |v| depth(v) }.max || 0)
          else 0
          end
        end
      end

      BUILT_IN = { json: Stdlib, oj: Oj }.freeze

      def self.resolve(setting, max_nesting: 64)
        case setting
        when Symbol, String
          BUILT_IN.fetch(setting.to_sym) { raise ConfigurationError, "unknown JSON codec #{setting.inspect}" }
                  .new(max_nesting: max_nesting)
        else
          unless setting.respond_to?(:dump) && setting.respond_to?(:load)
            raise ConfigurationError, "a JSON codec must respond to dump and load"
          end

          setting
        end
      end

      def self.default
        @default ||= Stdlib.new
      end
    end
  end
end
