# frozen_string_literal: true

require "test_helper"

# Cross-process brokers against real services.
module BrokerContract
  def receive(timeout = 3) = Timeout.timeout(timeout) { @received.pop }

  def start_broker
    @received = Queue.new
    broker.start { |message| @received << message }
  end

  def test_round_trip
    start_broker
    broker.publish(GemStack::Realtime::Message.new("1-a", "news", "posted", { "n" => 1 }))
    message = receive

    assert_equal ["1-a", "news", "posted", { "n" => 1 }], message.to_a
  end

  # Presence travels through the broker as JSON: another process (node) joins
  # and leaves, this one tracks a connection; every list converges.
  def test_presence_across_processes
    GemStack::Realtime.reset!
    GemStack::Realtime.broker = broker
    GemStack::Realtime.listen!
    other = lambda do |op, meta|
      data = { "node" => "other-process", "entries" => [["rooms:1", "42", meta]] }
      broker.publish(GemStack::Realtime::Message.new(GemStack::Realtime.next_id, GemStack::Realtime::Presence::CHANNEL,
                                                     op, data))
    end
    ids = -> { GemStack::Realtime.present_on("rooms:1").map { |entry| entry["id"] }.sort }

    other.call("join", { "id" => "42", "name" => "Ada" })
    GemStack::Realtime.presence.track("rooms:1", "7", { "id" => "7" })

    assert(wait_for { ids.call == %w[42 7] }, "both present, got #{ids.call}")
    assert_equal({ "id" => "42", "name" => "Ada" }, GemStack::Realtime.present_on("rooms:1").find { |e| e["id"] == "42" }["meta"])
    other.call("leave", nil)

    assert(wait_for { ids.call == %w[7] }, "the other process left, got #{ids.call}")
  ensure
    GemStack::Realtime.reset!
    @broker = nil
  end

  def wait_for(timeout = 3)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now > deadline
    yield
  end
end

class PostgresBrokerTest < Minitest::Test
  include BrokerContract

  URL = ENV.fetch("GEMSTACK_TEST_DATABASE_URL", nil)

  def setup
    skip "set GEMSTACK_TEST_DATABASE_URL to a PostgreSQL URL to run the PostgreSQL broker tests" unless
      URL&.start_with?("postgres")
    require "gemstack/db"
    GemStack.config.db.url = URL
    GemStack::DB::Tasks.create
  end

  def teardown = @broker&.stop

  def broker = @broker ||= GemStack::Realtime::Brokers::Postgres.new

  def test_broadcasts_are_transactional
    start_broker
    db = GemStack::DB.connection
    db.transaction(rollback: :always) { broker.publish(GemStack::Realtime::Message.new("rb", "news", "x", nil)) }
    db.transaction { broker.publish(GemStack::Realtime::Message.new("ok", "news", "x", nil)) }

    assert_equal "ok", receive.id, "the rolled-back broadcast is never delivered"
  end

  def test_payload_limit
    big = GemStack::Realtime::Message.new("1", "news", "x", { "blob" => "x" * 10_000 })

    error = assert_raises(GemStack::Realtime::PayloadTooLarge) { broker.publish(big) }
    assert_includes error.message, "Redis broker"
  end
end

class RedisBrokerTest < Minitest::Test
  include BrokerContract

  URL = ENV.fetch("GEMSTACK_TEST_REDIS_URL", nil)

  def setup
    skip "set GEMSTACK_TEST_REDIS_URL to run the Redis broker tests" unless URL
  end

  def teardown = @broker&.stop

  def broker = @broker ||= GemStack::Realtime::Brokers::Redis.new(url: URL, channel: "gemstack-test-#{Process.pid}")

  def test_large_payloads_are_fine
    start_broker
    broker.publish(GemStack::Realtime::Message.new("1", "news", "x", { "blob" => "x" * 100_000 }))

    assert_equal 100_000, receive.data["blob"].size
  end
end
