# frozen_string_literal: true

require "test_helper"

# End to end through a real Puma server and raw sockets.
class RealtimeServerTest < Minitest::Test
  include RealtimeServer

  def setup
    GemStack::Realtime.reset!
    GemStack::Realtime.broker = GemStack::Realtime::Brokers::Memory.new
    GemStack::Realtime.channels.clear
    GemStack.channels do
      channel "news"
      channel "orders:*" do |id, request|
        request.get_header("HTTP_AUTHORIZATION") == "Bearer #{id}"
      end
    end
    start_server
  end

  def teardown = stop_server

  def test_stream_headers_and_events
    client = connect("channels=news")

    assert_equal 200, client.status
    assert_equal "text/event-stream; charset=utf-8", client.headers["content-type"]
    assert_equal "no-cache, no-transform", client.headers["cache-control"]
    assert(wait_until { GemStack::Realtime.hub.subscriber_count("news") == 1 })

    id = GemStack.broadcast("news", "posted", { title: "Hello" })
    event = client.next_event

    assert_equal id, event["id"]
    assert_equal({ "id" => id, "channel" => "news", "event" => "posted", "data" => { "title" => "Hello" } },
                 event["data"])
  end

  def test_multiplexed_channels_and_authorization
    client = connect("channels=news,orders:7", "Authorization" => "Bearer 7")
    wait_until { GemStack::Realtime.hub.subscriber_count("orders:7") == 1 }
    GemStack.broadcast("orders:8", "ignored")
    GemStack.broadcast("orders:7", "order.updated", { status: "shipped" })

    assert_equal "orders:7", client.next_event["data"]["channel"]
  end

  def test_a_refused_channel_does_not_break_the_others
    client = connect("channels=news,secret")

    assert_equal 200, client.status
    event = client.next_event["data"]

    assert_equal %w[gemstack.denied secret], event.values_at("event", "channel")
    wait_until { GemStack::Realtime.hub.subscriber_count("news") == 1 }
    GemStack.broadcast("news", "still-works")

    assert_equal "still-works", client.next_event["data"]["event"]
    assert_equal 0, GemStack::Realtime.hub.subscriber_count("secret")
  end

  def test_refused_channels_are_reported_and_invalid_requests_are_json_errors
    refused = connect("channels=orders:7", "Authorization" => "Bearer 8")

    assert_equal 200, refused.status, "the stream opens and says which channels were refused"
    assert_equal %w[gemstack.denied orders:7], refused.next_event["data"].values_at("event", "channel")
    assert_equal 403, connect("channels=news", "Origin" => "https://evil.example").status
    assert_equal 400, connect("channels=").status
    assert_equal 400, connect("channels=#{Array.new(60) { |i| "c#{i}" }.join(",")}").status
  end

  def test_replay_after_reconnect
    first = connect("channels=news")
    wait_until { GemStack::Realtime.hub.subscriber_count("news") == 1 }
    seen = GemStack.broadcast("news", "one")
    first.next_event
    first.close
    wait_until { GemStack::Realtime.hub.subscriber_count("news").zero? }
    GemStack.broadcast("news", "two") # while disconnected
    GemStack.broadcast("news", "three")

    second = connect("channels=news", "Last-Event-ID" => seen)

    assert_equal(%w[two three], [second.next_event, second.next_event].map { |e| e["data"]["event"] })
  end

  def test_gap_event_when_replay_is_impossible
    client = connect("channels=news&last_event_id=long-gone")

    assert_equal "gemstack.gap", client.next_event["data"]["event"]
  end

  def test_disconnects_are_noticed
    client = connect("channels=news")

    assert(wait_until { GemStack::Realtime.hub.subscriber_count("news") == 1 })
    client.close

    assert(wait_until { GemStack::Realtime.hub.subscriber_count("news").zero? })
  end

  # The point of hijacking: open streams don't hold Puma's (2) threads.
  def test_open_streams_do_not_consume_server_threads
    20.times { connect("channels=news") }

    assert(wait_until { GemStack::Realtime.hub.subscriber_count("news") == 20 })
    socket = TCPSocket.new("127.0.0.1", @port)
    socket.write("GET /api/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    response = Timeout.timeout(2) { socket.read }

    assert_includes response, '{"status":"ok"}'
    GemStack.broadcast("news", "to-all")

    assert(@clients.all? { |c| c.next_event["data"]["event"] == "to-all" })
  ensure
    socket&.close
  end
end

class HeartbeatTest < Minitest::Test
  include RealtimeServer

  def setup
    GemStack::Realtime.reset!
    GemStack::Realtime.broker = GemStack::Realtime::Brokers::Memory.new
    GemStack.config.realtime.heartbeat = 0.1
    GemStack::Realtime::Streamer.reset!
    GemStack.channels { channel "news" }
    start_server
  end

  def teardown
    stop_server
    GemStack.config.realtime.heartbeat = 15
  end

  def test_welcome_then_ping_events
    client = connect("channels=news")

    assert_includes client.raw, "retry: 3000"
    welcome = client.next_event(skip: [])["data"]

    assert_equal ["gemstack.welcome", "sse"], [welcome["event"], welcome.dig("data", "transport")]
    assert_equal "gemstack.ping", client.next_event(skip: [])["data"]["event"], "visible to EventSource, unlike comments"
    refute_includes client.raw, "id:", "system events don't reset Last-Event-ID"
  end
end
