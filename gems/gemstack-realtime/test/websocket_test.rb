# frozen_string_literal: true

require "test_helper"

# The WebSocket transport end to end: a real Puma server, raw sockets.
class WebSocketTest < Minitest::Test
  include RealtimeServer

  Codec = GemStack::Realtime::WebSocket::Codec

  def setup
    GemStack::Realtime.reset!
    GemStack::Realtime.broker = GemStack::Realtime::Brokers::Memory.new
    GemStack::Realtime.channels.clear
    @config = GemStack.config.realtime
    @saved = %i[heartbeat max_messages_per_second max_message_size allowed_origins presence_grace transports]
             .to_h { |k| [k, @config.public_send(k)] }
    @config.presence_grace = 0.3
    GemStack.channels do
      identify do |request|
        id = request.get_header("HTTP_AUTHORIZATION").to_s[/Bearer (\d+)/, 1]
        id && { id: id.to_i, name: "User #{id}" }
      end
      channel "news"
      channel "orders:*" do |id, request|
        identity(request)&.fetch(:id).to_s == id
      end
      channel "rooms:*", presence: true
      receive "rooms:*" do |message|
        case message.event
        when "say"
          GemStack.broadcast(message.channel, "said", { "body" => message.data["body"], "by" => message.identity[:id] })
          { "room" => message.params.first }
        when "invalid" then raise GemStack::BadRequest.new("body is required", code: "body_required")
        when "boom" then raise "secret internal detail"
        end
      end
    end
    start_server
  end

  def teardown
    stop_server
    @saved.each { |key, value| @config.public_send(:"#{key}=", value) }
  end

  def user(id, **) = websocket(headers: { "Authorization" => "Bearer #{id}" }, **)

  def test_handshake_and_welcome
    client = websocket

    assert_equal 101, client.status
    assert_equal Codec.accept_key("dGhlIHNhbXBsZSBub25jZQ=="), client.headers["sec-websocket-accept"]
    welcome = client.welcome

    assert_equal 15, welcome["heartbeat"]
    assert_match(/\A\h{16}\z/, welcome["connection_id"])
  end

  def test_subscribe_receive_and_unsubscribe
    client = websocket

    assert_equal({ "type" => "subscribed", "channel" => "news", "ref" => 1 }, client.subscribe("news", ref: 1))
    id = GemStack.broadcast("news", "posted", { title: "Hello" })

    assert_equal({ "type" => "event", "id" => id, "channel" => "news", "event" => "posted",
                   "data" => { "title" => "Hello" } }, client.next_json("event"))
    client.send_json(type: "unsubscribe", channel: "news")

    assert_equal "unsubscribed", client.next_json["type"]
    assert_equal 0, GemStack::Realtime.hub.subscriber_count("news")
  end

  def test_refused_channels
    client = user(7)

    assert_equal "forbidden", client.subscribe("secret")["code"], "undeclared: deny by default"
    assert_equal "forbidden", client.subscribe("orders:8")["code"]
    assert_equal "subscribed", client.subscribe("orders:7")["type"]
    assert_equal "invalid_channel", client.subscribe("bad channel!")["code"]
    assert_equal "invalid_channel", client.subscribe(GemStack::Realtime::Presence::CHANNEL)["code"]
    assert_equal "forbidden", websocket.subscribe("orders:7")["code"], "anonymous"
  end

  def test_replay_after_a_reconnect_and_gap_when_too_late
    websocket # the process listens once a connection arrives
    first = GemStack.broadcast("news", "a")
    GemStack.broadcast("news", "b")
    client = websocket
    client.subscribe("news", last_id: first)

    assert_equal "b", client.next_json("event")["event"], "missed events are replayed"
    other = websocket
    other.subscribe("news", last_id: "unknown-id")

    assert_equal({ "type" => "gap", "channel" => "news" }, other.next_json("gap"))
  end

  def test_messages_from_the_browser
    alice = user(1)
    bob = user(2)
    alice.subscribe("rooms:9")
    bob.subscribe("rooms:9")
    alice.send_json(type: "message", channel: "rooms:9", event: "say", data: { body: "hi" }, ref: 5)

    assert_equal({ "type" => "reply", "ref" => 5, "ok" => true, "data" => { "room" => "9" } }, alice.next_json("reply"))
    assert_equal({ "body" => "hi", "by" => 1 }, bob.next_json("event")["data"], "the handler's broadcast")
  end

  def test_message_errors
    client = user(1)
    client.send_json(type: "message", channel: "rooms:9", event: "say", ref: 1)

    assert_equal "not_subscribed", client.next_json("reply").dig("error", "code")
    client.subscribe("news")
    client.send_json(type: "message", channel: "news", event: "say", ref: 2)

    assert_equal "no_handler", client.next_json("reply").dig("error", "code")
    client.subscribe("rooms:9")
    client.send_json(type: "message", channel: "rooms:9", event: "invalid", ref: 3)

    assert_equal({ "code" => "body_required", "message" => "body is required" }, client.next_json("reply")["error"])
    client.send_json(type: "message", channel: "rooms:9", event: "boom", ref: 4)
    reply = client.next_json("reply")

    assert_equal "internal_error", reply.dig("error", "code")
    refute_includes reply.to_s, "secret internal detail"
  end

  def test_presence_across_connections
    alice = user(1)
    alice.subscribe("rooms:1")
    bob = user(2)
    subscribed = bob.subscribe("rooms:1")

    assert_equal [1, 2].map(&:to_s), subscribed["presence"].map { |p| p["id"] }.sort
    assert_equal({ "type" => "presence", "channel" => "rooms:1", "event" => "join", "id" => "2",
                   "meta" => { "id" => 2, "name" => "User 2" } }, alice.next_json("presence"))
    second_tab = user(2)
    second_tab.subscribe("rooms:1")
    second_tab.close

    assert(wait_until { GemStack::Realtime.hub.subscriber_count("rooms:1") == 2 })
    bob.close

    assert_equal({ "type" => "presence", "channel" => "rooms:1", "event" => "leave", "id" => "2" },
                 alice.next_json("presence"), "leaves only when the last tab closes, and only once")
    assert_equal(["1"], GemStack::Realtime.present_on("rooms:1").map { |p| p["id"] })
  end

  def test_a_quick_reconnect_is_not_a_leave_and_join
    alice = user(1)
    alice.subscribe("rooms:1")
    bob = user(2)
    bob.subscribe("rooms:1")
    alice.next_json("presence") # bob joined
    bob.close
    user(2).subscribe("rooms:1") # back within the grace period
    sleep 0.6

    assert_equal %w[1 2], GemStack::Realtime.present_on("rooms:1").map { |p| p["id"] }.sort
    alice.send_json(type: "ping")

    assert_equal "pong", alice.next_json["type"], "no presence event in between"
  end

  def test_transports_setting
    @config.transports = %i[sse]
    disabled = websocket

    assert_equal 404, disabled.status
    assert_includes disabled.body, "transport_disabled"
    @config.transports = %i[websocket]
    sse = connect("channels=news")

    assert_equal 426, sse.status
    assert_equal "websocket", sse.headers["upgrade"]
  end

  def test_anonymous_connections_are_not_present
    client = websocket

    assert_equal [], client.subscribe("rooms:1")["presence"]
  end

  def test_origins
    assert_equal 101, websocket(origin: "http://localhost").status
    assert_equal 101, websocket(origin: nil).status, "non-browser clients"
    refused = websocket(origin: "https://evil.example")

    assert_equal 403, refused.status
    assert_includes refused.body, "origin_forbidden"
    @config.allowed_origins = ["https://app.example"]

    assert_equal 101, websocket(origin: "https://app.example").status
  end

  def test_bad_handshakes
    assert_equal 400, websocket(key: "nope").status
    mismatch = websocket(headers: { "Sec-WebSocket-Version" => "8" }) # sent next to 13: "13, 8"

    assert_equal 426, mismatch.status
    assert_equal "13", mismatch.headers["sec-websocket-version"]
  end

  def test_json_ping_and_protocol_pings
    client = websocket
    client.send_json(type: "ping")

    assert_equal({ "type" => "pong" }, client.next_json("pong"))
    client.send_frame(0x9, "are you there")

    assert_equal([0xA, "are you there"], client.next_frame.then { |op, payload| [op, payload] })
  end

  def test_protocol_errors_close_with_a_code
    {
      [0x2, "binary"] => Codec::UNSUPPORTED_DATA,
      [0x1, "x" * 70_000] => Codec::MESSAGE_TOO_BIG
    }.each do |(opcode, payload), code|
      client = websocket
      client.send_frame(opcode, payload)
      opcode_received, body = client.next_frame

      assert_equal 0x8, opcode_received
      assert_equal code, body.unpack1("n")
      assert client.closed?
    end
  end

  def test_close_handshake
    client = websocket
    client.send_frame(0x8, [1000].pack("n"))

    assert_equal [0x8, [1000].pack("n")], client.next_frame
    assert client.closed?
  end

  def test_rate_limit
    @config.max_messages_per_second = 3
    client = websocket
    5.times { |i| client.send_json(type: "subscribe", channel: "news", ref: i) }
    replies = Array.new(5) { client.next_json }

    assert_includes replies.map { |r| r.dig("error", "code") }, "rate_limited"
  end
end

class WebSocketHeartbeatTest < Minitest::Test
  include RealtimeServer

  def setup
    GemStack::Realtime.reset!
    GemStack::Realtime.broker = GemStack::Realtime::Brokers::Memory.new
    @heartbeat = GemStack.config.realtime.heartbeat
    GemStack.config.realtime.heartbeat = 0.2
    start_server
  end

  def teardown
    stop_server
    GemStack.config.realtime.heartbeat = @heartbeat
  end

  def test_pings_and_disconnects_silent_clients
    client = websocket

    assert_equal 0x9, client.next_frame.first, "the server pings"
    assert client.closed?(3), "a client that never answers is disconnected after three heartbeats"
  end

  def test_answering_keeps_the_connection
    client = websocket
    6.times do
      opcode, payload = client.next_frame
      client.send_frame(0xA, payload) if opcode == 0x9
    end

    client.send_json(type: "ping")

    assert_equal "pong", client.next_json("pong")["type"]
  end
end
