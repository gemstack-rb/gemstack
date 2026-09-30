# frozen_string_literal: true

module GemStack
  module Cache
    # A thread-safe, per-process LRU cache with expiry. Values are stored
    # marshalled, so callers never share (and can't mutate) cached objects —
    # the same semantics as the Redis store. With several Puma workers each
    # has its own copy; use Redis to share a cache across processes.
    class MemoryStore < Store
      Entry = Struct.new(:data, :expires_at)

      def initialize(max_entries: 10_000, **)
        super(**)
        @max_entries = max_entries
        @entries = {}
        @mutex = Mutex.new
      end

      def size = @entries.size
      def clear = @mutex.synchronize { @entries.clear }

      def increment(key, by = 1, expires_in: default_expires_in)
        normalized = normalize(key)
        @mutex.synchronize do
          entry = live_entry(normalized)
          value = (entry ? Integer(load(entry.data)) : 0) + by
          store(normalized, value, entry ? entry.expires_at : expires_at(expires_in))
          value
        end
      end

      private

      def read_entry(key)
        @mutex.synchronize do
          entry = live_entry(key) or return MISSING
          @entries[key] = @entries.delete(key) # mark as most recently used
          load(entry.data)
        end
      end

      def write_entry(key, value, expires_in)
        data = dump(value)
        @mutex.synchronize { store_data(key, data, expires_at(expires_in)) }
      end

      def delete_entry(key) = @mutex.synchronize { !@entries.delete(key).nil? }

      # Callers hold the mutex.
      def live_entry(key)
        entry = @entries[key]
        return nil unless entry
        return entry unless entry.expires_at && entry.expires_at <= monotonic

        @entries.delete(key)
        nil
      end

      def store(key, value, expires_at) = store_data(key, dump(value), expires_at)

      def store_data(key, data, expires_at)
        @entries.delete(key)
        @entries[key] = Entry.new(data, expires_at)
        @entries.shift while @entries.size > @max_entries # Hash order = LRU order
        true
      end
    end
  end
end
