# frozen_string_literal: true

ENV["GEMSTACK_ENV"] = "test"
require "gemstack/realtime"
require "gemstack/realtime/testing"
require "minitest/autorun"
require "socket"
require "timeout"
require "puma"

GemStack.config.logger.output = nil

# Reads Server-Sent Events from a raw socket.
class SSEClient
  attr_reader :status, :headers

  def initialize(port, query, headers = {})
    @socket = TCPSocket.new("127.0.0.1", port)
    extra = headers.map { |k, v| "#{k}: #{v}\r\n" }.join
    @socket.write("GET /api/realtime?#{query} HTTP/1.1\r\nHost: localhost\r\n#{extra}\r\n")
    @buffer = +""
    head = read_until("\r\n\r\n")
    lines = head.split("\r\n")
    @status = lines.first.split[1].to_i
    @headers = lines[1..].to_h { |line| line.split(": ", 2).then { |k, v| [k.downcase, v] } }
  end

  SKIPPED = %w[gemstack.welcome gemstack.ping].freeze

  # The next event (a Hash of SSE fields; "data" parsed as JSON), skipping
  # comments and the transport's own welcome/ping events (pass skip: [] to see them).
  def next_event(timeout = 3, skip: SKIPPED)
    Timeout.timeout(timeout) do
      loop do
        block = read_until("\n\n")
        fields = block.lines.map(&:chomp).reject { |l| l.start_with?(":") }.to_h { |l| l.split(": ", 2) }
        next if fields.empty? || fields.keys == ["retry"]

        fields["data"] = JSON.parse(fields["data"]) if fields["data"]
        next if skip.include?(fields.dig("data", "event"))

        return fields
      end
    end
  end

  def raw(timeout = 3) = Timeout.timeout(timeout) { read_until("\n\n") }
  def body_rest = @buffer
  def close = @socket.close

  private

  def read_until(separator)
    until (index = @buffer.index(separator))
      @buffer << @socket.readpartial(4096)
    end
    part = @buffer[0...index]
    @buffer = @buffer[(index + separator.size)..]
    part
  end
end

# A minimal WebSocket client over a raw socket: masked frames out, JSON in.
class WSClient
  Codec = GemStack::Realtime::WebSocket::Codec
  attr_reader :status, :headers, :body, :welcome

  def initialize(port, origin: "http://localhost", headers: {}, key: "dGhlIHNhbXBsZSBub25jZQ==", path: "/api/realtime")
    @socket = TCPSocket.new("127.0.0.1", port)
    extra = headers.merge("Origin" => origin).compact.map { |k, v| "#{k}: #{v}\r\n" }.join
    @socket.write("GET #{path} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                  "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n#{extra}\r\n")
    @buffer = "".b
    head = read_until("\r\n\r\n")
    lines = head.split("\r\n")
    @status = lines.first.split[1].to_i
    @headers = lines[1..].to_h { |line| line.split(": ", 2).then { |k, v| [k.downcase, v] } }
    @body = @status == 101 ? nil : @buffer.dup
    @welcome = next_json("welcome") if open?
  end

  def open? = @status == 101

  def send_json(hash) = send_frame(0x1, JSON.generate(hash))

  def send_frame(opcode, payload, fin: true)
    payload = payload.b
    mask = Random.bytes(4)
    head = [(fin ? 0x80 : 0) | opcode].pack("C")
    length = payload.bytesize
    head << if length < 126 then [0x80 | length].pack("C")
            elsif length < 65_536 then [0x80 | 126, length].pack("Cn")
            else [0x80 | 127, length].pack("CQ>")
            end
    @socket.write(head + mask + Codec.unmask(payload, mask))
  end

  # The next server frame: [opcode, payload].
  def next_frame(timeout = 3)
    Timeout.timeout(timeout) do
      fill(2)
      first, second = @buffer.unpack("CC")
      length = second & 0x7F
      offset = 2
      if length == 126
        fill(4)
        length = @buffer.byteslice(2, 2).unpack1("n")
        offset = 4
      elsif length == 127
        fill(10)
        length = @buffer.byteslice(2, 8).unpack1("Q>")
        offset = 10
      end
      fill(offset + length)
      payload = @buffer.byteslice(offset, length)
      @buffer = @buffer.byteslice(offset + length, @buffer.bytesize)
      [first & 0x0F, payload]
    end
  end

  # The next JSON message (skipping pings), optionally the next of a type.
  def next_json(type = nil, timeout = 3)
    Timeout.timeout(timeout) do
      loop do
        opcode, payload = next_frame(timeout)
        next unless opcode == 0x1

        message = JSON.parse(payload.force_encoding("UTF-8"))
        return message if type.nil? || message["type"] == type
      end
    end
  end

  def subscribe(channel, **extra)
    send_json({ type: "subscribe", channel: channel }.merge(extra))
    next_json(nil)
  end

  # Reads (and drops) whatever arrives until the server closes the socket.
  def closed?(timeout = 2)
    Timeout.timeout(timeout) { loop { @socket.readpartial(4096) } }
  rescue IOError, SystemCallError # EOFError is an IOError
    true
  rescue Timeout::Error
    false
  end

  def close = @socket.close

  private

  def fill(bytes)
    @buffer << @socket.readpartial(4096) while @buffer.bytesize < bytes
  end

  def read_until(separator)
    until (index = @buffer.index(separator))
      @buffer << @socket.readpartial(4096)
    end
    part = @buffer.byteslice(0, index)
    @buffer = @buffer.byteslice(index + separator.bytesize, @buffer.bytesize)
    part
  end
end

# Boots a real Puma server around a GemStack HTTP app with the realtime middleware.
module RealtimeServer
  def start_server(threads: 2)
    config = GemStack::HTTP::Config.new
    config.middleware.insert_before(GemStack::HTTP::Middleware::HealthCheck, GemStack::Realtime::Middleware,
                                    path: "/api/realtime")
    router = GemStack::HTTP::Router.new(prefix: "/api").draw do
      get "/slow", to: ->(_) { sleep 0.2 and [200, {}, ["slow"]] }
    end
    app = GemStack::HTTP::App.new(config: config, router: router)
    @server = Puma::Server.new(app, nil, min_threads: threads, max_threads: threads)
    @server.add_tcp_listener("127.0.0.1", 0)
    @port = @server.connected_ports.first
    @server.run
  end

  def stop_server
    @clients&.each { |c| c.close rescue nil } # rubocop:disable Style/RescueModifier
    @server&.stop(true)
    GemStack::Realtime.reset!
    GemStack::Realtime::Streamer.reset!
    GemStack::Realtime::Dispatcher.reset!
  end

  def connect(query, headers = {})
    (@clients ||= []) << SSEClient.new(@port, query, headers)
    @clients.last
  end

  def websocket(**)
    (@clients ||= []) << WSClient.new(@port, **)
    @clients.last
  end

  def wait_until(timeout = 3)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now > deadline
    yield
  end
end
