# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"

module GemStack
  # The type system shared by model fields, request schemas, serializers and
  # the TypeScript/OpenAPI generators — one name per concept everywhere:
  #
  #   field :price, :decimal          (model)
  #   required :price, :decimal       (request schema)
  #   attribute :price, :decimal      (serializer)
  #   price: string                   (generated TypeScript)
  #
  # Each type knows how to coerce input (strings from forms and query strings,
  # JSON values), how to dump values into JSON, and its TypeScript / OpenAPI
  # representation. Register your own with Types.register.
  module Types
    # Raised by a coercer when a value can't be converted; the message is the
    # client-facing validation message ("must be an integer").
    class CoercionError < StandardError; end

    Type = Struct.new(:name, :ts, :openapi, :coercer, :dumper, keyword_init: true) do
      def coerce(value) = coercer ? coercer.call(value) : value
      def dump(value) = value.nil? || dumper.nil? ? value : dumper.call(value)
    end

    INTEGER = /\A[-+]?\d+\z/
    NUMBER = /\A[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/i
    TRUE_VALUES = [true, 1, "1", "true", "TRUE", "True", "on", "yes"].freeze
    FALSE_VALUES = [false, 0, "0", "false", "FALSE", "False", "off", "no"].freeze

    CLASS_ALIASES = {
      String => :string, Integer => :integer, Float => :float, BigDecimal => :decimal,
      TrueClass => :boolean, FalseClass => :boolean, Date => :date, Time => :datetime,
      DateTime => :datetime, Hash => :json
    }.freeze

    @registry = {}

    class << self
      def register(name, ts:, openapi:, coerce: nil, dump: nil)
        @registry[name.to_sym] = Type.new(name: name.to_sym, ts: ts, openapi: openapi.freeze,
                                          coercer: coerce, dumper: dump).freeze
      end

      # Accepts a type name (:string) or a Ruby class (String, Integer, ...).
      def fetch(name)
        key = CLASS_ALIASES.fetch(name, name)
        @registry.fetch(key.to_sym) do
          raise ArgumentError, "unknown type #{name.inspect}; known types: #{@registry.keys.join(", ")}"
        end
      end

      def type?(name)
        CLASS_ALIASES.key?(name) || ((name.is_a?(Symbol) || name.is_a?(String)) && @registry.key?(name.to_sym))
      end

      def names = @registry.keys

      def fail!(message) = raise(CoercionError, message)

      def to_integer(value)
        case value
        when Integer then value
        when Float then value == value.floor ? value.to_i : fail!("must be an integer")
        when String then value.strip.match?(INTEGER) ? Integer(value.strip, 10) : fail!("must be an integer")
        else fail!("must be an integer")
        end
      end

      def to_float(value)
        case value
        when Float then value
        when Numeric then value.to_f
        when String then value.strip.match?(NUMBER) ? Float(value.strip) : fail!("must be a number")
        else fail!("must be a number")
        end
      end

      def to_decimal(value)
        case value
        when BigDecimal then value
        when Integer then BigDecimal(value)
        when Float then BigDecimal(value.to_s)
        when String then value.strip.match?(NUMBER) ? BigDecimal(value.strip) : fail!("must be a decimal number")
        else fail!("must be a decimal number")
        end
      end

      def to_boolean(value)
        return true if TRUE_VALUES.include?(value)
        return false if FALSE_VALUES.include?(value)

        fail!("must be true or false")
      end

      def to_date(value)
        case value
        when DateTime, Time then value.to_date
        when Date then value
        when String then Date.iso8601(value.strip)
        else fail!("must be a date (YYYY-MM-DD)")
        end
      rescue ArgumentError # includes Date::Error
        fail!("must be a date (YYYY-MM-DD)")
      end

      def to_datetime(value)
        case value
        when Time then value
        when DateTime then value.to_time
        when String then parse_time(value.strip)
        else fail!("must be a date-time (ISO 8601)")
        end
      end

      private

      # ISO 8601 with a zone, or a zone-less "YYYY-MM-DDTHH:MM[:SS]" (as sent
      # by <input type="datetime-local">), which is read as UTC.
      def parse_time(string)
        Time.iso8601(string)
      rescue ArgumentError
        match = string.match(/\A(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::(\d\d))?\z/)
        fail!("must be a date-time (ISO 8601)") unless match
        Time.utc(*match.captures.compact.map(&:to_i))
      end
    end

    string = lambda do |value|
      case value
      when String then value
      when Symbol, Numeric then value.to_s
      else fail!("must be a string")
      end
    end
    iso_time = ->(value) { (value.respond_to?(:to_time) ? value.to_time : value).utc.iso8601(3) }

    register :string, ts: "string", openapi: { type: "string" }, coerce: string
    register :text, ts: "string", openapi: { type: "string" }, coerce: string
    register :integer, ts: "number", openapi: { type: "integer" }, coerce: method(:to_integer)
    register :bigint, ts: "number", openapi: { type: "integer", format: "int64" }, coerce: method(:to_integer)
    register :references, ts: "number", openapi: { type: "integer", format: "int64" }, coerce: method(:to_integer)
    register :float, ts: "number", openapi: { type: "number" }, coerce: method(:to_float)
    # Decimals travel as strings so no precision is lost in JavaScript.
    register :decimal, ts: "string", openapi: { type: "string", format: "decimal" },
                       coerce: method(:to_decimal),
                       dump: ->(value) { (value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)).to_s("F") }
    register :boolean, ts: "boolean", openapi: { type: "boolean" }, coerce: method(:to_boolean)
    register :date, ts: "string", openapi: { type: "string", format: "date" },
                    coerce: method(:to_date), dump: lambda(&:iso8601)
    register :datetime, ts: "string", openapi: { type: "string", format: "date-time" },
                        coerce: method(:to_datetime), dump: iso_time
    register :uuid, ts: "string", openapi: { type: "string", format: "uuid" },
                    coerce: lambda { |value|
                      value.is_a?(String) && value.match?(UUID) ? value.downcase : fail!("must be a UUID")
                    }
    register :json, ts: "unknown", openapi: {}
  end
end
