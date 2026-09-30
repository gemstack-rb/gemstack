# frozen_string_literal: true

require "test_helper"

class GatewayTest < Minitest::Test
  Upstream = GemStack::Dev::Gateway::Upstream

  def setup
    @api = FakeUpstream.new do |socket, head|
      body = head.lines.first.split[1]
      if (length = head[/content-length: (\d+)/i, 1])
        rest = head.split("\r\n\r\n", 2)[1]
        rest << socket.readpartial(4096) while rest.bytesize < length.to_i
        body = "#{body} #{rest}"
      end
      FakeUpstream.respond(socket, "api:#{body}")
    end
    @web = FakeUpstream.new { |socket, head| FakeUpstream.respond(socket, "web:#{head.lines.first.split[1]}") }
    @gateway = start_gateway(api: upstream(@api), frontend: upstream(@web))
  end

  def teardown
    @gateway.stop
    @api.stop
    @web.stop
  end

  def upstream(fake) = Upstream.new(:x, "127.0.0.1", fake.port, "x")

  def start_gateway(**)
    GemStack::Dev::Gateway.new(port: 0, api_path: "/api", bind: ["127.0.0.1"], **).start
  end

  def http(gateway = @gateway)
    Net::HTTP.new("127.0.0.1", gateway.port)
  end

  def test_routes_by_path_prefix
    assert_equal "api:/api/products?page=2", http.get("/api/products?page=2").body
    assert_equal "api:/api", http.get("/api").body
    assert_equal "web:/", http.get("/").body
    assert_equal "web:/apiary", http.get("/apiary").body
    assert_equal "web:/_next/static/chunk.js", http.get("/_next/static/chunk.js").body
  end

  def test_forwards_request_bodies
    response = http.post("/api/items", '{"name":"Lamp"}', "content-type" => "application/json")

    assert_equal 'api:/api/items {"name":"Lamp"}', response.body
  end

  def test_rewrites_headers
    http.get("/api/x", "host" => "localhost:3000", "x-forwarded-for" => "6.6.6.6")
    head = @api.requests.pop

    assert_match(/^Host: localhost:3000\r$/i, head)
    assert_match(/^X-Forwarded-Host: localhost:3000\r$/, head)
    assert_match(/^X-Forwarded-For: 127\.0\.0\.1\r$/, head)
    assert_match(/^X-Forwarded-Proto: http\r$/, head)
    assert_match(/^Connection: close\r$/, head)
    refute_includes head, "6.6.6.6"
    refute_match(/keep-alive/i, head)
  end

  def test_api_unavailable_is_json_503
    down = start_gateway(api: Upstream.new(:api, "127.0.0.1", GemStack::Dev::Ports.free, "api"),
                         frontend: upstream(@web))
    response = http(down).get("/api/health")

    assert_equal "503", response.code
    assert_equal "upstream_unavailable", JSON.parse(response.body)["error"]["code"]
  ensure
    down&.stop
  end

  def test_frontend_unavailable_is_an_auto_refreshing_page
    down = start_gateway(api: upstream(@api), frontend: Upstream.new(:web, "127.0.0.1", GemStack::Dev::Ports.free, "w"))
    response = http(down).get("/", "accept" => "text/html")

    assert_equal "503", response.code
    assert_includes response.body, 'http-equiv="refresh"'
    assert_includes response.body, "Next.js is starting"
  ensure
    down&.stop
  end

  def test_no_frontend_configured
    api_only = start_gateway(api: upstream(@api))

    assert_equal "503", http(api_only).get("/").code
    assert_equal "api:/api/x", http(api_only).get("/api/x").body
  ensure
    api_only&.stop
  end

  def test_empty_api_path_routes_everything_to_api
    root = start_gateway(api: upstream(@api), frontend: upstream(@web), api_path: "")

    assert_equal "api:/anything", http(root).get("/anything").body
  ensure
    root&.stop
  end

  def test_streams_responses_without_buffering
    release = Queue.new
    streamer = FakeUpstream.new do |socket, _|
      socket.write("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n")
      socket.write("data: one\n\n")
      release.pop
      socket.write("data: two\n\n")
    end
    gateway = start_gateway(api: upstream(streamer))
    client = TCPSocket.new("127.0.0.1", gateway.port)
    client.write("GET /api/events HTTP/1.1\r\nHost: x\r\n\r\n")
    received = +""
    received << client.readpartial(1024) until received.include?("data: one")

    refute_includes received, "data: two" # first event arrived while the upstream was still waiting
    release << true
    received << client.readpartial(1024) until received.include?("data: two")
  ensure
    client&.close
    gateway&.stop
    streamer&.stop
  end

  def test_websocket_upgrade_is_piped_both_ways
    echo = FakeUpstream.new do |socket, _|
      socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
      loop { socket.write("echo:#{socket.readpartial(1024)}") }
    end
    gateway = start_gateway(api: upstream(@api), frontend: upstream(echo))
    client = TCPSocket.new("127.0.0.1", gateway.port)
    client.write("GET /_next/hmr HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
    response = +""
    response << client.readpartial(1024) until response.include?("\r\n\r\n")

    assert_includes response, "101 Switching Protocols"
    head = echo.requests.pop

    assert_match(/^Connection: Upgrade\r$/, head)
    refute_match(/^Connection: close/, head)
    client.write("ping")

    assert_equal "echo:ping", client.readpartial(1024)
  ensure
    client&.close
    gateway&.stop
    echo&.stop
  end

  def test_port_in_use
    blocker = TCPServer.new("127.0.0.1", 0)
    gateway = GemStack::Dev::Gateway.new(port: blocker.addr[1], api_path: "/api", api: upstream(@api),
                                         bind: ["127.0.0.1"])

    error = assert_raises(GemStack::Error) { gateway.start }
    assert_includes error.message, "already in use"
  ensure
    blocker&.close
  end

  def test_api_request_matching
    gateway = GemStack::Dev::Gateway.new(port: 0, api_path: "/api/", api: nil)

    assert gateway.api_request?("/api")
    assert gateway.api_request?("/api/x")
    refute gateway.api_request?("/apix")
    refute gateway.api_request?("/")
  end
end
