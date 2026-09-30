# frozen_string_literal: true

require "gemstack/core"

module GemStack
  # Application caching:
  #
  #   GemStack.cache.fetch("product:#{id}", expires_in: 300) { Product.find(id) }
  #   GemStack.cache.fetch([:stats, Date.today]) { expensive_report }   # array keys
  #   GemStack.cache.increment("signups")
  #   GemStack.cache.delete("product:#{id}")
  #
  # Stores are swappable (config.cache.store): :memory (default), :null
  # (default in test), :redis, or any object implementing the Store interface.
  # Redis is never required.
  module Cache
    class Config < Settings
      setting :store, default: -> { GemStack.env.test? ? :null : :memory }
      # Prefix for every key ("shop:product:1"). Required for Redis#clear.
      setting :namespace, default: -> { GemStack.config.name }
      # Seconds; nil = no expiry unless given per call.
      setting :default_expires_in, default: nil
      # MemoryStore: maximum entries per process before the least recently used are evicted.
      setting :max_entries, default: 10_000
      setting :redis_url, default: -> { ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
      setting :redis_pool_size, default: -> { Integer(ENV.fetch("GEMSTACK_MAX_THREADS", 5)) }
    end

    class << self
      def build(setting = GemStack.config.cache.store, config: GemStack.config.cache)
        options = { namespace: config.namespace, default_expires_in: config.default_expires_in }
        case setting
        when :memory, "memory" then MemoryStore.new(max_entries: config.max_entries, **options)
        when :null, "null" then NullStore.new(**options)
        when :redis, "redis"
          RedisStore.new(url: config.redis_url, pool_size: config.redis_pool_size, **options)
        when Store then setting
        else
          raise ConfigurationError, "unknown cache store #{setting.inspect}" unless setting.respond_to?(:fetch)

          setting
        end
      end
    end
  end

  class << self
    def cache
      @cache ||= Cache.build
    end

    attr_writer :cache
  end
end

require_relative "cache/store"
require_relative "cache/memory_store"
require_relative "cache/null_store"
require_relative "cache/redis_store"

GemStack::Config.namespace(:cache, GemStack::Cache::Config)
