# frozen_string_literal: true

require "socket"
require "json"

module GemStack
  module Dev
    # The development gateway: one public origin in front of Next.js and the
    # Ruby API.
    #
    # For each connection it reads only the request line and headers, picks
    # an upstream by path (api_path → API, everything else → frontend), adds
    # X-Forwarded-* headers and then copies raw bytes in both directions.
    # Because it never interprets bodies, streaming responses, Server-Sent
    # Events and WebSocket upgrades (Next.js HMR, realtime) just work.
    #
    # Each request gets its own upstream connection (`Connection: close`
    # upstream), so routing stays correct per request without parsing
    # response framing. That trade-off is fine on localhost and is the reason
    # this gateway is for development only.
    class Gateway
      Upstream = Struct.new(:name, :host, :port, :label) do
        def to_s = "#{host}:#{port}"
      end

      MAX_HEAD = 64 * 1024
      CONNECT_TIMEOUT = 2
      HOP_BY_HOP = %w[connection keep-alive proxy-connection].freeze
      FORWARDED = %w[x-forwarded-for x-forwarded-proto x-forwarded-host x-forwarded-port].freeze

      attr_reader :port
      attr_accessor :api, :frontend

      def initialize(port:, api_path:, api:, frontend: nil, bind: %w[127.0.0.1 ::1], on_error: nil)
        @port = port
        @api_path = api_path.to_s.chomp("/")
        @api = api
        @frontend = frontend
        @bind = Array(bind)
        @on_error = on_error
        @servers = []
        @threads = []
      end

      def start
        @bind.each do |host|
          server = listen(host)
          next unless server

          @port = server.addr[1] if @port.zero? # port 0: let the OS choose (tests)
          @servers << server
        end
        raise Error, "could not listen on any of #{@bind.join(", ")}" if @servers.empty?

        @threads = @servers.map { |server| Thread.new { accept_loop(server) } }
        self
      end

      def stop
        @servers.each { |server| server.close unless server.closed? }
        @threads.each { |thread| thread.join(1) }
        @servers.clear
      end

      def api_request?(path)
        return true if @api_path.empty?

        path == @api_path || path.start_with?("#{@api_path}/")
      end

      private

      def listen(host)
        TCPServer.new(host, @port)
      rescue Errno::EADDRINUSE
        stop
        raise Error,
              "port #{@port} is already in use on #{host}. Stop the other process or run PORT=#{@port + 1} gemstack dev"
      rescue Errno::EADDRNOTAVAIL, Errno::EAFNOSUPPORT, SocketError
        nil # e.g. no IPv6 loopback on this machine
      end

      def accept_loop(server)
        loop do
          client = server.accept
          Thread.new(client) { |socket| handle(socket) }
        end
      rescue IOError, Errno::EBADF, Errno::EINVAL
        nil # server closed
      end

      def handle(client)
        head, rest = read_head(client)
        return unless head

        request_line, *header_lines = head.split("\r\n")
        _method, target, = request_line.split(" ", 3)
        return respond(client, 400, "text/plain", "Bad Request") unless target

        path = target.sub(%r{\Ahttps?://[^/]+}i, "").split("?", 2).first
        api = api_request?(path)
        upstream = api ? @api : @frontend
        return unavailable(client, api, header_lines, nil) unless upstream

        server = connect(upstream)
        return unavailable(client, api, header_lines, upstream) unless server

        server.write("#{request_line}\r\n#{rewrite(header_lines, client).join("\r\n")}\r\n\r\n")
        server.write(rest) unless rest.empty?
        relay(client, server)
      rescue IOError, SystemCallError
        nil # client or upstream went away
      rescue StandardError => e
        @on_error&.call(e)
      ensure
        [client, server].each { |socket| socket&.close unless socket&.closed? }
      end

      def read_head(client)
        buffer = String.new(encoding: Encoding::BINARY)
        until (index = buffer.index("\r\n\r\n"))
          return nil if buffer.bytesize > MAX_HEAD

          buffer << client.readpartial(16 * 1024)
        end
        [buffer.byteslice(0, index), buffer.byteslice(index + 4, buffer.bytesize)]
      rescue IOError, SystemCallError # EOFError is an IOError
        nil
      end

      def rewrite(lines, client)
        upgrade = upgrade?(lines)
        host = nil
        kept = lines.reject do |line|
          name = line[/\A[^:]+/].to_s.strip.downcase
          host = line.split(":", 2).last.strip if name == "host"
          FORWARDED.include?(name) || (!upgrade && HOP_BY_HOP.include?(name))
        end
        kept << "Connection: close" unless upgrade
        kept << "X-Forwarded-For: #{client_ip(client)}"
        kept << "X-Forwarded-Proto: http"
        kept << "X-Forwarded-Host: #{host}" if host
        kept << "X-Forwarded-Port: #{@port}"
      end

      def upgrade?(lines)
        connection = lines.find { |l| l.match?(/\Aconnection\s*:/i) }
        connection&.match?(/upgrade/i) && lines.any? { |l| l.match?(/\Aupgrade\s*:/i) }
      end

      def client_ip(client)
        client.remote_address.ip_address
      rescue StandardError
        "127.0.0.1"
      end

      def connect(upstream)
        Socket.tcp(upstream.host, upstream.port, connect_timeout: CONNECT_TIMEOUT)
      rescue SystemCallError, SocketError, IOError
        nil
      end

      # Upstream → client on this thread; client → upstream on a helper
      # thread. The exchange ends when the upstream closes (after its
      # response, or when a WebSocket/stream ends).
      def relay(client, server)
        pump = Thread.new do
          IO.copy_stream(client, server)
          server.close_write
        rescue IOError, SystemCallError
          nil
        end
        IO.copy_stream(server, client)
      rescue IOError, SystemCallError
        nil
      ensure
        pump&.kill
      end

      def unavailable(client, api, header_lines, upstream)
        name = api ? "Ruby API" : "Next.js"
        state = upstream ? "is starting or not running" : "is not configured"
        message = "#{name} #{state}. Check the terminal running `gemstack dev`."
        if api
          body = JSON.generate(error: { code: "upstream_unavailable", message: message })
          respond(client, 503, "application/json", body)
        elsif header_lines.any? { |l| l.match?(%r{\Aaccept\s*:.*text/html}i) }
          respond(client, 503, "text/html; charset=utf-8", waiting_page(name, message, refresh: !upstream.nil?))
        else
          respond(client, 503, "text/plain", message)
        end
      end

      def respond(client, status, type, body)
        reason = { 400 => "Bad Request", 503 => "Service Unavailable" }.fetch(status, "Error")
        client.write("HTTP/1.1 #{status} #{reason}\r\ncontent-type: #{type}\r\ncontent-length: #{body.bytesize}\r\n" \
                     "cache-control: no-store\r\nretry-after: 1\r\nconnection: close\r\n\r\n#{body}")
      end

      def waiting_page(name, message, refresh:)
        <<~HTML
          <!doctype html>
          <html lang="en"><head><meta charset="utf-8"><title>GemStack · #{name}</title>
          #{'<meta http-equiv="refresh" content="1">' if refresh}
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            body{font:16px/1.5 system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;
                 background:#0b0d12;color:#e6e8ee}
            main{max-width:32rem;padding:2rem;text-align:center}
            .dot{display:inline-block;width:.6rem;height:.6rem;border-radius:50%;background:#f5b041;
                 margin-right:.5rem;animation:p 1s infinite alternate}
            @keyframes p{to{opacity:.3}} code{background:#1c2030;padding:.1rem .35rem;border-radius:4px}
          </style></head>
          <body><main><h1>GemStack</h1><p><span class="dot"></span>#{message.sub(/`([^`]+)`/, '<code>\1</code>')}</p>
          <p style="color:#8a90a2">#{"This page refreshes automatically." if refresh}</p></main></body></html>
        HTML
      end
    end
  end
end
