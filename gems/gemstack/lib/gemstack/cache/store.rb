# frozen_string_literal: true

require "digest"

module GemStack
  module Cache
    # The store interface. Subclasses implement read_entry / write_entry /
    # delete_entry / clear (and may override increment for atomicity).
    #
    # Keys may be strings, symbols, arrays of parts, or objects with
    # #cache_key (GemStack models have one); they are namespaced and hashed
    # when longer than MAX_KEY bytes. Values must be Marshal-able.
    class Store
      MAX_KEY = 200
      MISSING = Object.new.freeze

      attr_reader :namespace, :default_expires_in

      def initialize(namespace: nil, default_expires_in: nil)
        @namespace = namespace&.to_s
        @default_expires_in = default_expires_in
      end

      # Returns the cached value, or computes it with the block, stores and
      # returns it. nil results are cached too. force: true recomputes.
      def fetch(key, expires_in: default_expires_in, force: false)
        normalized = normalize(key)
        unless force
          value = read_entry(normalized)
          return value unless value.equal?(MISSING)
        end
        raise ArgumentError, "fetch needs a block on a cache miss" unless block_given?

        value = yield
        write_entry(normalized, value, expires_in)
        value
      end

      def read(key)
        value = read_entry(normalize(key))
        value.equal?(MISSING) ? nil : value
      end

      def write(key, value, expires_in: default_expires_in)
        write_entry(normalize(key), value, expires_in)
        value
      end

      def exist?(key) = !read_entry(normalize(key)).equal?(MISSING)
      def delete(key) = delete_entry(normalize(key))

      # Not atomic in the base class; stores override it where they can.
      def increment(key, by = 1, expires_in: default_expires_in)
        normalized = normalize(key)
        current = read_entry(normalized)
        value = (current.equal?(MISSING) ? 0 : Integer(current)) + by
        write_entry(normalized, value, expires_in)
        value
      end

      def decrement(key, by = 1, **) = increment(key, -by, **)

      def normalize(key)
        raw = key_part(key)
        full = namespace ? "#{namespace}:#{raw}" : raw
        full.bytesize > MAX_KEY ? "#{full[0, 100]}:sha256:#{Digest::SHA256.hexdigest(full)}" : full
      end

      private

      def key_part(key)
        case key
        when Array then key.map { |part| key_part(part) }.join("/")
        when String, Symbol, Numeric then key.to_s
        else key.respond_to?(:cache_key) ? key.cache_key.to_s : key.to_s
        end
      end

      def dump(value) = Marshal.dump(value)
      def load(data) = Marshal.load(data) # rubocop:disable Security/MarshalLoad -- only data this process wrote

      def expires_at(expires_in)
        expires_in ? monotonic + Float(expires_in) : nil
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
