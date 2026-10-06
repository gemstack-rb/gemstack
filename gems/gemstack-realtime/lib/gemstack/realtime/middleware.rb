# frozen_string_literal: true

require "uri"

module GemStack
  module Realtime
    # GET <api_path>/realtime with `Upgrade: websocket` — the realtime endpoint.
    #
    # Checks the handshake and the Origin (only the API's own origin, plus
    # config.http.cors.origins or realtime.allowed_origins), identifies the
    # connection with config/channels.rb's `identify` while the request's
    # cookies are at hand, then takes the socket over (Rack full hijack, as
    # Puma supports), answers 101 and hands it to the Streamer. Subscriptions
    # and messages then travel over the WebSocket (WebSocket::Connection).
    #
    # Deprecated: GET <api_path>/realtime?channels=a,b[&last_event_id=...]
    # without an Upgrade is the Server-Sent Events stream older realtime.ts
    # clients use. Validates and authorizes the channels (400 as a JSON error; 403 only when
    # none is allowed — refused channels otherwise get a gemstack.denied event), then
    # takes the socket over from the server (Rack full hijack, supported by
    # Puma) and hands it to the Streamer, freeing the request thread. The
    # response is a standard text/event-stream: events missed since
    # Last-Event-ID are replayed first, or a `gemstack.gap` event tells the
    # client to refetch because they're no longer available.
    class Middleware
      HEADERS = [
        "HTTP/1.1 200 OK", "content-type: text/event-stream; charset=utf-8", "cache-control: no-cache, no-transform",
        "x-accel-buffering: no", "x-content-type-options: nosniff", "connection: close"
      ].freeze

      def initialize(app, path: nil)
        @app = app
        @path = path
      end

      def call(env)
        return @app.call(env) unless env[Rack::PATH_INFO] == path && env[Rack::REQUEST_METHOD] == "GET"
        return websocket(env) if env["HTTP_UPGRADE"].to_s.casecmp?("websocket")

        deprecated_sse
        request = Rack::Request.new(env)
        requested = requested_channels(request)
        channels, denied = requested.partition { |channel| Realtime.channels.authorized?(channel, request) }
        if channels.empty?
          raise Forbidden.new("Not allowed to subscribe to #{denied.join(", ")}",
                              code: "channel_forbidden")
        end

        Realtime.listen!
        last_id = env["HTTP_LAST_EVENT_ID"] || request.GET["last_event_id"]
        preamble = preamble(channels, last_id, denied)
        env["rack.hijack?"] ? hijack(env, channels, preamble) : stream(channels, preamble)
      end

      private

      def path = @path ||= Realtime.config.path

      def websocket(env)
        key = env["HTTP_SEC_WEBSOCKET_KEY"]
        unless env["HTTP_CONNECTION"].to_s.downcase.include?("upgrade") && WebSocket::Codec.valid_key?(key)
          raise BadRequest.new("Invalid WebSocket handshake", code: "invalid_handshake")
        end
        unless env["HTTP_SEC_WEBSOCKET_VERSION"] == "13"
          return [426, { "sec-websocket-version" => "13", "content-type" => "text/plain" }, ["WebSocket version 13"]]
        end

        request = Rack::Request.new(env)
        raise Forbidden.new("Cross-origin WebSocket refused", code: "origin_forbidden") unless allowed_origin?(request)
        unless env["rack.hijack?"]
          raise ServiceUnavailable.new("WebSockets need a server with Rack hijacking, such as Puma",
                                       code: "websocket_unsupported")
        end

        open_websocket(env, request, key)
      end

      def open_websocket(env, request, key)
        identity = Realtime.channels.identify_request(request)
        Realtime.listen!
        io = env["rack.hijack"].call
        io.write(WebSocket::Codec.handshake_response(key))
        streamer = Streamer.instance
        connection = WebSocket::Connection.new(io, request: request, identity: identity, streamer: streamer)
        connection.welcome
        streamer.add(connection)
        [200, {}, []] # ignored by the server after a full hijack
      end

      # Browsers always send Origin with a WebSocket; other clients (servers,
      # mobile apps) may not, and aren't subject to cross-site hijacking.
      def allowed_origin?(request)
        origin = request.get_header("HTTP_ORIGIN")
        return true if origin.nil? || origin.empty?

        allowed = Realtime.config.allowed_origins
        return allowed.include?(origin) if allowed
        return true if GemStack.config.http.cors.origins.include?(origin)

        uri = URI.parse(origin)
        uri.host.to_s.casecmp?(request.host) && uri.port == request.port
      rescue URI::InvalidURIError
        false
      end

      def deprecated_sse
        return if @sse_warned

        @sse_warned = true
        GemStack.logger.warn("realtime: a client used the deprecated Server-Sent Events transport; update " \
                             "frontend/lib/gemstack/realtime.ts to the WebSocket client (docs/realtime.md)")
      end

      def requested_channels(request)
        channels = request.GET["channels"].to_s.split(",").map(&:strip).reject(&:empty?).uniq
        raise BadRequest.new("Give at least one channel: ?channels=a,b", code: "channels_required") if channels.empty?

        max = Realtime.config.max_channels
        raise BadRequest.new("At most #{max} channels per connection", code: "too_many_channels") if channels.size > max

        invalid = channels.grep_v(CHANNEL_NAME)
        if invalid.any?
          raise InvalidChannel.new("Invalid channel name(s): #{invalid.join(", ")}",
                                   code: "invalid_channel")
        end

        channels
      end

      # One multiplexed stream serves many subscriptions, so a refused channel
      # doesn't fail the others: its handlers get a `gemstack.denied` event.
      def preamble(channels, last_id, denied)
        messages, gap = Realtime.hub.replay(channels, last_id)
        text = "retry: #{Realtime.config.retry_ms}\n\n"
        denied.each { |channel| text << system_event("gemstack.denied", channel) }
        messages.each { |message| text << message.sse }
        text << system_event("gemstack.gap", nil) if gap
        text
      end

      def system_event(name, channel) = "data: #{Message.new(nil, channel, name, nil).json}\n\n"

      def hijack(env, channels, preamble)
        io = env["rack.hijack"].call
        io.write("#{HEADERS.join("\r\n")}\r\n\r\n")
        streamer = Streamer.instance
        connection = Connection.new(io, channels, streamer: streamer)
        Realtime.hub.add(connection)
        connection.push(preamble)
        streamer.add(connection)
        [200, {}, []] # ignored by the server after a full hijack
      end

      # Servers without full hijack: stream from the request thread (holds it
      # for the life of the connection).
      def stream(channels, preamble)
        unless @warned
          GemStack.logger.warn("realtime: server doesn't support rack.hijack; streaming on a request thread")
        end
        @warned = true
        body = QueueBody.new(channels, preamble)
        [200, { "content-type" => "text/event-stream; charset=utf-8", "cache-control" => "no-cache, no-transform" },
         body]
      end

      # A Rack body fed by the hub (fallback path). Closing it unsubscribes.
      class QueueBody
        attr_reader :channels

        def initialize(channels, preamble)
          @channels = channels.freeze
          @queue = Queue.new
          @queue << preamble
          Realtime.hub.add(self)
        end

        def push(bytes) = @queue << bytes
        def deliver(message) = push(message.sse)
        def closed? = @queue.closed?

        def each
          while (chunk = @queue.pop)
            yield chunk
          end
        end

        def close
          Realtime.hub.remove(self)
          @queue.close
        end
      end
    end
  end
end
