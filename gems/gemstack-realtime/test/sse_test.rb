# frozen_string_literal: true

require "test_helper"
require "net/http"

# The Server-Sent Events transport has the WebSocket transport's features:
# identity, presence, browser messages (POST) — and both share channels.
class SSETransportTest < Minitest::Test
  include RealtimeServer

  def setup
    GemStack::Realtime.reset!
    GemStack::Realtime.broker = GemStack::Realtime::Brokers::Memory.new
    GemStack::Realtime.channels.clear
    @config = GemStack.config.realtime
    @saved = %i[presence_grace transports allowed_origins].to_h { |k| [k, @config.public_send(k)] }
    @config.presence_grace = 0.3
    GemStack.channels do
      identify do |request|
        id = request.get_header("HTTP_AUTHORIZATION").to_s[/Bearer (\d+)/, 1]
        id && { id: id.to_i, name: "User #{id}" }
      end
      channel "news"
      channel "rooms:*", presence: true
      receive "rooms:*" do |message|
        raise GemStack::BadRequest.new("say something", code: "empty") if message.data.to_h["body"].to_s.empty?

        GemStack.broadcast(message.channel, "said", { "body" => message.data["body"], "by" => message.identity[:id] })
        { "room" => message.params.first }
      end
    end
    start_server
  end

  def teardown
    stop_server
    @saved.each { |key, value| @config.public_send(:"#{key}=", value) }
  end

  def stream(channels, user = nil) = connect("channels=#{channels}", user ? { "Authorization" => "Bearer #{user}" } : {})

  def post(body, user: nil, origin: nil, type: "application/json")
    request = Net::HTTP::Post.new("/api/realtime", { "Content-Type" => type, "Authorization" => user && "Bearer #{user}",
                                                     "Origin" => origin }.compact)
    request.body = body.is_a?(String) ? body : JSON.generate(body)
    response = Net::HTTP.start("127.0.0.1", @port) { |http| http.request(request) }
    [response.code.to_i, JSON.parse(response.body)]
  end

  def error(...) = post(...).then { |status, body| [status, body.dig("error", "code")] }

  def test_presence_over_sse
    alice = stream("rooms:1", 1)

    assert_equal %w[1], alice.next_event["data"]["data"].map { |p| p["id"] }, "gemstack.presence on open"
    bob = stream("rooms:1", 2)

    assert_equal %w[1 2], bob.next_event["data"]["data"].map { |p| p["id"] }.sort
    assert_equal({ "id" => "2", "meta" => { "id" => 2, "name" => "User 2" } }, alice.next_event["data"]["data"])
    bob.close

    assert_equal ["presence.leave", { "id" => "2" }], alice.next_event["data"].values_at("event", "data")
  end

  def test_messages_over_post
    listener = stream("rooms:9", 2)
    wait_until { GemStack::Realtime.hub.subscriber_count("rooms:9") == 1 }
    status, body = post({ channel: "rooms:9", event: "say", data: { body: "hi" } }, user: 1)

    assert_equal [200, { "data" => { "room" => "9" } }], [status, body]
    listener.next_event # presence of user 2
    assert_equal({ "body" => "hi", "by" => 1 }, listener.next_event["data"]["data"])
  end

  def test_post_errors
    assert_equal [400, "empty"], error({ channel: "rooms:9", event: "say", data: {} })
    assert_equal [403, "forbidden"], error({ channel: "secret", event: "x" })
    assert_equal [404, "no_handler"], error({ channel: "news", event: "x" })
    assert_equal [400, "invalid_json"], error("{")
    assert_equal 415, post("{}", type: "text/plain").first, "JSON only: no cross-site form posts"
    assert_equal [403, "origin_forbidden"], error({ channel: "rooms:9", event: "say" }, origin: "https://evil.example")
  end

  def test_post_needs_the_sse_transport
    @config.transports = %i[websocket]

    assert_equal 426, post({ channel: "rooms:9", event: "say", data: { body: "x" } }).first
  end

  def test_a_stream_for_another_allowed_origin_carries_cors_headers
    @config.allowed_origins = ["https://app.example"]
    other = connect("channels=news", { "Origin" => "https://app.example" })

    assert_equal ["https://app.example", "true"], other.headers.values_at("access-control-allow-origin", "access-control-allow-credentials")
    assert_nil connect("channels=news").headers["access-control-allow-origin"], "same origin: none"
  end

  # One room, one user on each transport: they see each other and each other's messages.
  def test_websocket_and_sse_clients_share_channels_and_presence
    sse = stream("rooms:5", 1)
    sse.next_event # presence state
    ws = websocket(headers: { "Authorization" => "Bearer 2" })
    subscribed = ws.subscribe("rooms:5")

    assert_equal %w[1 2], subscribed["presence"].map { |p| p["id"] }.sort
    assert_equal "presence.join", sse.next_event["data"]["event"]
    ws.send_json(type: "message", channel: "rooms:5", event: "say", data: { body: "from ws" }, ref: 1)

    assert_equal({ "body" => "from ws", "by" => 2 }, sse.next_event["data"]["data"])
    assert_equal({ "body" => "from ws", "by" => 2 }, ws.next_json("event")["data"], "its own broadcast too")
    post({ channel: "rooms:5", event: "say", data: { body: "from sse" } }, user: 1)

    assert_equal({ "body" => "from sse", "by" => 1 }, ws.next_json("event")["data"])
  end
end
