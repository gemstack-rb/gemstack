# frozen_string_literal: true

require "test_helper"

class ChannelsTest < Minitest::Test
  def channels
    GemStack::Realtime::Channels.new.tap do |c|
      c.draw do
        channel "announcements"
        channel "orders:*" do |id, request|
          id == "42" && request == :viewer
        end
        channel "rooms:*:messages"
      end
    end
  end

  def test_rules
    c = channels

    assert c.authorized?("announcements", nil)
    assert c.authorized?("orders:42", :viewer)
    refute c.authorized?("orders:42", :stranger)
    refute c.authorized?("orders:7", :viewer)
    assert c.authorized?("rooms:lobby:messages", nil)
    refute c.authorized?("rooms:lobby", nil)
    refute c.authorized?("orders:42:secret", :viewer), "* matches exactly one segment"
    refute c.authorized?("unknown", nil), "deny by default"
  end

  def test_invalid_patterns
    assert_raises(ArgumentError) { GemStack::Realtime::Channels.new.channel("bad channel") }
  end
end

class HubTest < Minitest::Test
  M = GemStack::Realtime::Message

  FakeConnection = Struct.new(:channels, :received) do
    def push(bytes) = received << bytes
    # Like the SSE connection.
    def deliver(message) = push(message.sse)
  end

  def setup = @hub = GemStack::Realtime::Hub.new(replay_size: 3, replay_ttl: 60)

  def test_delivers_to_subscribers_of_the_channel_only
    a = @hub.add(FakeConnection.new(%w[orders:1], []))
    b = @hub.add(FakeConnection.new(%w[orders:2 news], []))

    assert_equal 1, @hub.deliver(M.new("1", "orders:1", "updated", { "n" => 1 }))
    assert_equal 1, a.received.size
    assert_empty b.received
    assert_match(/\Aid: 1\ndata: \{.*"channel":"orders:1".*\}\n\n\z/, a.received.first)
    @hub.remove(a)

    assert_equal 0, @hub.subscriber_count("orders:1")
  end

  def test_replay_after_last_event_id
    %w[1 2 3].each { |id| @hub.deliver(M.new(id, id == "2" ? "other" : "orders:1", "e", nil)) }
    messages, gap = @hub.replay(%w[orders:1], "1")

    assert_equal ["3"], messages.map(&:id)
    refute gap
  end

  def test_gap_when_the_event_is_no_longer_in_history
    %w[1 2 3 4].each { |id| @hub.deliver(M.new(id, "c", "e", nil)) } # replay_size 3 drops "1"

    assert_equal [[], true], @hub.replay(%w[c], "1")
    assert_equal [[], false], @hub.replay(%w[c], nil)
  end
end

class BroadcastTest < Minitest::Test
  include GemStack::Realtime::Testing

  Order = Struct.new(:id, :total, :secret)

  class OrderSerializer < GemStack::Serializer
    attributes id: :integer, total: :decimal
  end

  def test_broadcast_serializes_with_the_conventional_serializer
    id = GemStack.broadcast("orders:1", "order.updated", Order.new(1, BigDecimal("9.5"), "hidden"))

    assert_match(/\A\d+-\h{8}\z/, id)
    assert_equal({ id: 1, total: "9.5" }, broadcasts.last.data)
    assert_broadcast "orders:1", "order.updated", data: { id: 1, total: "9.5" }
    refute_broadcast "orders:2"
  end

  def test_invalid_channel_names
    assert_raises(GemStack::Realtime::InvalidChannel) { GemStack.broadcast("bad channel!", "x") }
  end

  def test_unknown_broker
    assert_raises(GemStack::ConfigurationError) { GemStack::Realtime.build_broker(:carrier_pigeon) }
  end

  def test_listen_with_a_lazily_built_broker
    GemStack::Realtime.reset!
    GemStack.config.realtime.broker = :memory
    Timeout.timeout(2) { assert GemStack::Realtime.listen! } # must not deadlock
    assert_kind_of GemStack::Realtime::Brokers::Memory, GemStack::Realtime.broker
  ensure
    GemStack.config.realtime.broker = :test
    GemStack::Realtime.reset!
  end

  def test_default_broker_is_test_in_tests
    assert_equal :test, GemStack::Realtime::Config.new.broker
  end
end

class ConnectionTest < Minitest::Test
  class NullStreamer
    attr_reader :writes, :closed_connection

    def initialize = @writes = 0
    def want_write(_) = @writes += 1
    def closed(connection) = @closed_connection = connection
  end

  def test_push_writes_immediately_and_buffers_when_the_socket_is_full
    reader, writer = UNIXSocket.pair
    streamer = NullStreamer.new
    connection = GemStack::Realtime::Connection.new(writer, %w[c], streamer: streamer, max_buffer: 10_000_000)
    connection.push("hello")

    assert_equal "hello", reader.readpartial(100)
    connection.push("x" * 2_000_000) # larger than the socket buffer

    assert_predicate connection, :pending?
    assert_operator streamer.writes, :>=, 1
  ensure
    [reader, writer].each { |s| s&.close unless s&.closed? }
  end

  def test_slow_clients_are_disconnected
    reader, writer = UNIXSocket.pair
    streamer = NullStreamer.new
    connection = GemStack::Realtime::Connection.new(writer, %w[c], streamer: streamer, max_buffer: 1000)
    10.times { connection.push("y" * 500_000) }

    assert_predicate connection, :closed?
    assert_same connection, streamer.closed_connection
  ensure
    reader&.close
  end
end
