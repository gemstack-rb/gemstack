# frozen_string_literal: true

require "test_helper"

# The behaviour every store must have; included per store.
module StoreContract
  Point = Struct.new(:x, :y)

  def test_fetch_computes_once_and_caches_nil
    calls = 0
    2.times { assert_equal "v", store.fetch("k") { calls += 1 and "v" } }

    assert_equal 1, calls
    store.fetch("nil") { nil }

    assert store.exist?("nil")
    assert_nil store.fetch("nil") { flunk "should be cached" }
  end

  def test_force_recomputes
    store.write("k", 1)

    assert_equal 2, store.fetch("k", force: true) { 2 }
    assert_equal 2, store.read("k")
  end

  def test_read_write_delete
    assert_nil store.read("missing")
    store.write("k", { list: [1, 2], at: Time.utc(2026, 1, 1) })

    assert_equal({ list: [1, 2], at: Time.utc(2026, 1, 1) }, store.read("k"))
    assert store.delete("k")
    refute store.exist?("k")
  end

  def test_values_are_copies
    store.write("point", Point.new(1, 2))
    store.read("point").x = 99

    assert_equal 1, store.read("point").x
  end

  def test_array_and_record_keys
    record = Struct.new(:cache_key).new("product/1-123")
    store.write([:stats, 2026, record], "x")

    assert_equal "x", store.read([:stats, 2026, record])
    assert_equal "#{store.namespace}:stats/2026/product/1-123", store.normalize([:stats, 2026, record])
  end

  def test_long_keys_are_hashed
    key = "x" * 500

    assert_operator store.normalize(key).bytesize, :<, 250
    store.write(key, 1)

    assert_equal 1, store.read(key)
  end

  def test_expiry
    store.write("short", 1, expires_in: 0.05)

    assert_equal 1, store.read("short")
    sleep 0.08

    assert_nil store.read("short")
  end

  def test_increment_and_decrement
    assert_equal 1, store.increment("count")
    assert_equal 6, store.increment("count", 5)
    assert_equal 4, store.decrement("count", 2)
    assert_equal 4, store.read("count")
  end

  def test_clear
    store.write("a", 1)
    store.clear

    refute store.exist?("a")
  end

  def test_fetch_without_block_on_miss
    assert_raises(ArgumentError) { store.fetch("nothing") }
  end
end

class MemoryStoreTest < Minitest::Test
  include StoreContract

  def store = @store ||= GemStack::Cache::MemoryStore.new(namespace: "test", max_entries: 3)

  def test_least_recently_used_entries_are_evicted
    store.write("a", 1)
    store.write("b", 2)
    store.write("c", 3)
    store.read("a") # a is now most recently used
    store.write("d", 4)

    assert_equal([1, nil, 3, 4], %w[a b c d].map { |k| store.read(k) })
    assert_equal 3, store.size
  end

  def test_thread_safety
    threads = Array.new(8) { Thread.new { 100.times { store.increment("hits") } } }
    threads.each(&:join)

    assert_equal 800, store.read("hits")
  end
end

class NullStoreTest < Minitest::Test
  def test_never_caches
    store = GemStack::Cache::NullStore.new
    calls = 0
    2.times { store.fetch("k") { calls += 1 } }

    assert_equal 2, calls
    assert_nil store.read(store.write("k", 1) && "k")
  end
end

class RedisStoreTest < Minitest::Test
  include StoreContract

  URL = ENV.fetch("GEMSTACK_TEST_REDIS_URL", nil)

  def setup
    skip "set GEMSTACK_TEST_REDIS_URL to run Redis tests" unless URL
    store.clear
  end

  def store = @store ||= GemStack::Cache::RedisStore.new(url: URL, namespace: "gemstack-test-#{Process.pid}")

  def test_clear_only_touches_its_namespace
    other = GemStack::Cache::RedisStore.new(url: URL, namespace: "gemstack-other-#{Process.pid}")
    other.write("keep", 1)
    store.write("drop", 1)
    store.clear

    assert_equal 1, other.read("keep")
  ensure
    other&.clear
  end

  def test_clear_requires_a_namespace
    assert_raises(GemStack::Error) { GemStack::Cache::RedisStore.new(url: URL, namespace: nil).clear }
  end
end

class CacheConfigTest < Minitest::Test
  def test_defaults_and_building
    config = GemStack::Cache::Config.new

    assert_equal :null, config.store # test environment
    assert_kind_of GemStack::Cache::MemoryStore, GemStack::Cache.build(:memory, config: config)
    assert_kind_of GemStack::Cache::NullStore, GemStack::Cache.build(:null, config: config)
    custom = GemStack::Cache::MemoryStore.new

    assert_same custom, GemStack::Cache.build(custom, config: config)
    assert_raises(GemStack::ConfigurationError) { GemStack::Cache.build(:memcached, config: config) }
  end

  def test_global_accessor
    GemStack.cache = GemStack::Cache::MemoryStore.new

    assert_equal 1, GemStack.cache.fetch("x") { 1 }
  ensure
    GemStack.cache = nil
  end
end
