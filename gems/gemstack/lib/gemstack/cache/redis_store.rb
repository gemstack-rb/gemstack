# frozen_string_literal: true

module GemStack
  module Cache
    # A cache shared by every process, through Redis. Uses the `redis-client`
    # gem (add `gem "redis-client"` to the Gemfile) with a connection pool
    # sized to the server's threads, or any client object you pass that
    # responds to #call(*command) (a redis-client pool or connection).
    #
    #   config.cache.store = :redis                      # REDIS_URL
    #   config.cache.store = GemStack::Cache::RedisStore.new(client: my_pool, namespace: "shop")
    class RedisStore < Store
      attr_reader :client

      def initialize(url: nil, client: nil, pool_size: 5, **)
        super(**)
        @client = client || build_client(url, pool_size)
      end

      def increment(key, by = 1, expires_in: default_expires_in)
        normalized = normalize(key)
        value = client.call("INCRBY", normalized, by)
        client.call("PEXPIRE", normalized, (Float(expires_in) * 1000).round, "NX") if expires_in
        value
      end

      # Deletes only keys in this store's namespace (never FLUSHDB).
      def clear
        raise Error, "RedisStore#clear needs a namespace (config.cache.namespace)" unless namespace

        cursor = "0"
        loop do
          cursor, keys = client.call("SCAN", cursor, "MATCH", "#{namespace}:*", "COUNT", 500)
          client.call("UNLINK", *keys) unless keys.empty?
          break if cursor == "0"
        end
        true
      end

      private

      def read_entry(key)
        data = client.call("GET", key)
        return MISSING if data.nil?

        # Counters are stored as plain integers so INCRBY works on them.
        data.match?(/\A-?\d+\z/) ? Integer(data) : load(data.b)
      end

      def write_entry(key, value, expires_in)
        data = value.is_a?(Integer) ? value.to_s : dump(value)
        if expires_in
          client.call("SET", key, data, "PX", (Float(expires_in) * 1000).round)
        else
          client.call("SET", key, data)
        end
        true
      end

      def delete_entry(key) = client.call("DEL", key).positive?

      def build_client(url, pool_size)
        require "redis-client"
        RedisClient.config(url: url).new_pool(size: pool_size, timeout: 1.0)
      rescue LoadError
        raise ConfigurationError, 'the Redis cache store needs `gem "redis-client"` in the Gemfile'
      end
    end
  end
end
