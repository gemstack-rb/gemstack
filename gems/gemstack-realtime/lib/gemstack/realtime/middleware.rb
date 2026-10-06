# frozen_string_literal: true

require "uri"

module GemStack
  module Realtime
    # The realtime endpoint, <api_path>/realtime, with two transports
    # (config.realtime.transports) behind the same channels, presence and
    # handlers:
    #
    #   GET  + Upgrade: websocket   WebSocket: everything over one connection
    #                               (WebSocket::Connection has the protocol)
    #   GET  ?channels=a,b          Server-Sent Events: the stream of events
    #        [&last_event_id=…]     for those channels (reopened to change them)
    #   POST {channel, event, data} a browser message for a `receive` handler,
    #                               when it isn't on a WebSocket
    #
    # Every request checks the Origin (the API's own, config.http.cors.origins
    # or realtime.allowed_origins) and runs config/channels.rb's `identify`.
    # Long-lived connections take the socket over from the server (Rack full
    # hijack, as Puma supports) and live on the Streamer's event loop.
    class Middleware
      SSE_HEADERS = [
        "HTTP/1.1 200 OK", "content-type: text/event-stream; charset=utf-8", "cache-control: no-cache, no-transform",
        "x-accel-buffering: no", "x-content-type-options: nosniff", "connection: close"
      ].freeze

      def initialize(app, path: nil)
        @app = app
        @path = path
      end

      def call(env)
        return @app.call(env) unless env[Rack::PATH_INFO] == path

        request = Rack::Request.new(env)
        unless allowed_origin?(request)
          raise Forbidden.new("Cross-origin realtime request refused",
                              code: "origin_forbidden")
        end

        case env[Rack::REQUEST_METHOD]
        when "GET"
          websocket = env["HTTP_UPGRADE"].to_s.casecmp?("websocket")
          return transport_disabled(websocket ? :websocket : :sse) unless enabled?(websocket ? :websocket : :sse)

          websocket ? WebSocketHandshake.call(env, request) : stream(env, request)
        when "POST"
          enabled?(:sse) ? Messages.call(request) : transport_disabled(:sse)
        else
          raise MethodNotAllowed.new("Use GET or POST", headers: { "allow" => "GET, POST" })
        end
      end

      private

      def path = @path ||= Realtime.config.path
      def enabled?(transport) = Realtime.config.transports.map(&:to_sym).include?(transport)

      def transport_disabled(transport)
        if transport == :websocket
          raise NotFound.new("The WebSocket transport is disabled (config.realtime.transports)",
                             code: "transport_disabled")
        end

        body = JSON.generate(error: { code: "transport_disabled",
                                      message: "Server-Sent Events are disabled; use WebSocket" })
        [426, { "upgrade" => "websocket", "content-type" => "application/json" }, [body]]
      end

      # Browsers always send Origin with a WebSocket or a POST; same-origin
      # GETs and other clients (servers, mobile apps) may not, and aren't
      # subject to cross-site hijacking.
      def allowed_origin?(request)
        origin = request.get_header("HTTP_ORIGIN")
        return true if origin.nil? || origin.empty?

        allowed = Realtime.config.allowed_origins
        return allowed.include?(origin) if allowed
        return true if GemStack.config.http.cors.origins.include?(origin)

        same_origin?(request, origin)
      end

      def same_origin?(request, origin)
        uri = URI.parse(origin)
        uri.host.to_s.casecmp?(request.host) && uri.port == request.port
      rescue URI::InvalidURIError
        false
      end

      # The stream's response bypasses the CORS middleware: an allowed other
      # origin (EventSource withCredentials) needs these itself.
      def cors_headers(request)
        origin = request.get_header("HTTP_ORIGIN")
        return [] if origin.nil? || origin.empty? || same_origin?(request, origin)

        ["access-control-allow-origin: #{origin}", "access-control-allow-credentials: true", "vary: Origin"]
      end

      # ── Server-Sent Events ───────────────────────────────────────────────

      # Authorizes each channel (a refused one gets `gemstack.denied` and the
      # others keep working), tracks presence, replays what was missed since
      # Last-Event-ID — or sends `gemstack.gap` — then streams.
      def stream(env, request)
        requested = requested_channels(request)
        identity = Realtime.channels.identify_request(request)
        rules = requested.to_h { |channel| [channel, Realtime.channels.authorize(channel, request)] }
        channels = rules.select { |_, rule| rule }.keys
        Realtime.listen!
        last_id = env["HTTP_LAST_EVENT_ID"] || request.GET["last_event_id"]
        return stream_on_request_thread(channels, identity, last_id, rules) unless env["rack.hijack?"]

        io = env["rack.hijack"].call
        io.write("#{(SSE_HEADERS + cors_headers(request)).join("\r\n")}\r\n\r\n")
        streamer = Streamer.instance
        connection = Connection.new(io, channels, streamer: streamer, identity: identity)
        # Presence first, before the hub delivers to it: its own join isn't news to it.
        text = preamble(connection, rules)
        Realtime.hub.add(connection)
        connection.push(text << replay(connection, last_id))
        streamer.add(connection)
        [200, {}, []] # ignored by the server after a full hijack
      end

      def requested_channels(request)
        channels = request.GET["channels"].to_s.split(",").map(&:strip).reject(&:empty?).uniq
        raise BadRequest.new("Give at least one channel: ?channels=a,b", code: "channels_required") if channels.empty?

        max = Realtime.config.max_channels
        raise BadRequest.new("At most #{max} channels per connection", code: "too_many_channels") if channels.size > max

        invalid = channels.grep_v(CHANNEL_NAME) + (channels & [Presence::CHANNEL])
        if invalid.any?
          raise InvalidChannel.new("Invalid channel name(s): #{invalid.join(", ")}",
                                   code: "invalid_channel")
        end

        channels
      end

      def preamble(connection, rules)
        text = "retry: #{Realtime.config.retry_ms}\n\n"
        text << system_event("gemstack.welcome", nil, { "connection_id" => SecureRandom.hex(8), "transport" => "sse",
                                                        "heartbeat" => Realtime.config.heartbeat })
        rules.each do |channel, rule|
          if rule.nil?
            text << system_event("gemstack.denied", channel, "forbidden")
          elsif rule.presence
            text << system_event("gemstack.presence", channel, connection.track_presence(channel))
          end
        end
        text
      end

      def replay(connection, last_id)
        messages, gap = Realtime.hub.replay(connection.channels.to_a, last_id.to_s)
        text = messages.map(&:sse).join
        gap ? text + system_event("gemstack.gap", nil) : text
      end

      def system_event(name, channel, data = nil) = "data: #{Message.new(nil, channel, name, data).json}\n\n"

      # Servers without full hijack: stream from the request thread (holds it
      # for the life of the connection; no presence).
      def stream_on_request_thread(channels, identity, last_id, rules)
        unless @warned
          GemStack.logger.warn("realtime: server doesn't support rack.hijack; streaming on a request thread")
        end
        @warned = true
        body = QueueBody.new(channels, identity)
        body.push(rules.filter_map do |channel, rule|
          system_event("gemstack.denied", channel, "forbidden") unless rule
        end.join)
        messages, gap = Realtime.hub.replay(channels, last_id.to_s)
        messages.each { |message| body.push(message.sse) }
        body.push(system_event("gemstack.gap", nil)) if gap
        [200, { "content-type" => "text/event-stream; charset=utf-8", "cache-control" => "no-cache, no-transform" },
         body]
      end

      # A Rack body fed by the hub (fallback path). Closing it unsubscribes.
      class QueueBody
        attr_reader :channels, :identity

        def initialize(channels, identity)
          @channels = channels.freeze
          @identity = identity
          @queue = Queue.new
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

    # The WebSocket opening handshake: validates it, runs `identify` while the
    # request's cookies are at hand, then hands the socket to the Streamer.
    module WebSocketHandshake
      module_function

      def call(env, request)
        key = env["HTTP_SEC_WEBSOCKET_KEY"]
        unless env["HTTP_CONNECTION"].to_s.downcase.include?("upgrade") && WebSocket::Codec.valid_key?(key)
          raise BadRequest.new("Invalid WebSocket handshake", code: "invalid_handshake")
        end
        unless env["HTTP_SEC_WEBSOCKET_VERSION"] == "13"
          return [426, { "sec-websocket-version" => "13", "content-type" => "text/plain" }, ["WebSocket version 13"]]
        end
        unless env["rack.hijack?"]
          raise ServiceUnavailable.new("WebSockets need a server with Rack hijacking, such as Puma",
                                       code: "websocket_unsupported")
        end

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
    end

    # POST <api_path>/realtime {"channel", "event", "data"} — a browser message
    # for a `receive` handler over plain HTTP (the SSE transport's way up).
    # Allowed when the sender may subscribe to the channel. The handler's
    # return value is the response's "data"; its errors are the usual JSON
    # error envelope.
    module Messages
      module_function

      def call(request)
        unless request.media_type == "application/json"
          raise UnsupportedMediaType.new("Send JSON", code: "unsupported_media_type")
        end

        body = request.body.read(Realtime.config.max_message_size + 1).to_s
        if body.bytesize > Realtime.config.max_message_size
          raise GemStack::PayloadTooLarge.new("Message too large",
                                              code: "message_too_big")
        end

        message = JSON.parse(body)
        raise BadRequest.new("Expected a JSON object", code: "invalid_message") unless message.is_a?(Hash)

        handle(request, message["channel"].to_s, message["event"].to_s, message["data"])
      rescue JSON::ParserError
        raise BadRequest.new("Invalid JSON", code: "invalid_json")
      end

      def handle(request, channel, event, data)
        raise InvalidChannel.new("Invalid channel #{channel.inspect}", code: "invalid_channel") unless
          CHANNEL_NAME.match?(channel) && channel != Presence::CHANNEL

        Realtime.channels.identify_request(request)
        Realtime.channels.authorize(channel, request) or
          raise Forbidden.new("Not allowed on #{channel}", code: "forbidden")
        handler, params = Realtime.channels.receiver(channel)
        raise NotFound.new("#{channel} doesn't accept messages", code: "no_handler") unless handler

        sender = Sender.new(request, request.env[Channels::IDENTITY])
        result = handler.call(WebSocket::Incoming.new(channel, event, data, params, sender))
        [200, { "content-type" => "application/json" },
         [HTTP::JSONCodec.default.dump({ data: Serializer.render(result) })]]
      end

      Sender = Struct.new(:request, :identity)
    end
  end
end
