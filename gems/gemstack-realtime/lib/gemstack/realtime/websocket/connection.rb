# frozen_string_literal: true

require "json"
require "securerandom"

module GemStack
  module Realtime
    module WebSocket
      # One browser's WebSocket. Frames are parsed on the event loop; anything
      # that runs application code (authorizing a subscription, a `receive`
      # handler) goes through the connection's inbox to the Dispatcher, in order.
      #
      # Messages are JSON objects with a "type":
      #
      #   browser → server
      #     { type: "subscribe", channel, last_id?, ref? }   replays events after last_id
      #     { type: "unsubscribe", channel, ref? }
      #     { type: "message", channel, event, data?, ref? } handled by `receive` in config/channels.rb
      #     { type: "ping" }
      #
      #   server → browser
      #     { type: "welcome", connection_id, heartbeat }
      #     { type: "subscribed", channel, ref?, presence? } / { type: "unsubscribed", channel, ref? }
      #     { type: "denied", channel, ref?, code }          the channel was refused
      #     { type: "event", id, channel, event, data }      a broadcast
      #     { type: "gap", channel }                         events missed while away are gone: refetch
      #     { type: "presence", channel, event: "join"|"leave", id, meta? }
      #     { type: "reply", ref, ok, data? | error? }       the result of a "message"
      #     { type: "error", code, message }  { type: "pong" }
      class Connection < Realtime::Connection
        attr_reader :id, :request, :identity

        MAX_INBOX = 100

        def initialize(io, request:, identity:, streamer:, dispatcher: Dispatcher.instance,
                       max_buffer: Realtime.config.max_buffer)
          super(io, [], streamer: streamer, max_buffer: max_buffer)
          @id = SecureRandom.hex(8)
          @request = request
          @identity = identity
          @dispatcher = dispatcher
          @parser = Codec::Parser.new(max_message_size: Realtime.config.max_message_size)
          @inbox = []
          @inbox_mutex = Mutex.new
          @processing = false
          @presence = {} # channel => identity key
          @last_seen = monotonic
          @window = [monotonic.floor, 0]
        end

        def welcome = send_json(type: "welcome", connection_id: id, heartbeat: Realtime.config.heartbeat)

        # ── event loop ───────────────────────────────────────────────────

        def deliver(message)
          if message.event.start_with?("presence.")
            send_json(type: "presence", channel: message.channel, event: message.event.delete_prefix("presence."),
                      **message.data.transform_keys(&:to_sym))
          else
            push(message.ws_frame)
          end
        end

        # A ping frame every heartbeat; a client silent for three is gone.
        def heartbeat
          return fail_connection(Codec::GOING_AWAY, "heartbeat timeout") if silent?

          push(Codec.ping)
        end

        def receive(bytes)
          @last_seen = monotonic
          @parser.feed(bytes) { |type, payload, reason| frame(type, payload, reason) }
        rescue Codec::Error => e
          fail_connection(e.code, e.message)
        end

        # Called by the Streamer once the socket is gone.
        def disconnected
          tracked = @presence.dup
          @presence.clear
          return if tracked.empty?

          @dispatcher.schedule(-> { tracked.each { |channel, key| Realtime.presence.untrack(channel, key) } })
        end

        # ── dispatcher ───────────────────────────────────────────────────

        def process_inbox
          while (message = next_message)
            handle(message) unless closed?
          end
        end

        private

        def frame(type, payload, reason)
          case type
          when :text then incoming(payload)
          when :ping then push(Codec.pong(payload))
          when :close
            push(Codec.close(payload == 1005 ? Codec::NORMAL : payload, reason.to_s))
            close_after_flush
          end
        end

        def incoming(text)
          message = JSON.parse(text)
          return error("invalid_message", "expected a JSON object") unless message.is_a?(Hash)

          case message["type"]
          when "ping" then send_json(type: "pong")
          when "subscribe", "unsubscribe", "message" then enqueue(message)
          else error("unknown_type", "unknown message type #{message["type"].inspect}", message["ref"])
          end
        rescue JSON::ParserError
          error("invalid_json", "messages are JSON objects")
        end

        def enqueue(message)
          return reply_error(message["ref"], "rate_limited", "too many messages") if rate_limited?

          start = @inbox_mutex.synchronize do
            return reply_error(message["ref"], "busy", "too many pending messages") if @inbox.size >= MAX_INBOX

            @inbox << message
            !@processing && (@processing = true)
          end
          @dispatcher.schedule(self) if start
        end

        def next_message
          @inbox_mutex.synchronize do
            @inbox.shift.tap { |message| @processing = false unless message }
          end
        end

        def handle(message)
          case message["type"]
          when "subscribe" then subscribe(message["channel"].to_s, message["last_id"], message["ref"])
          when "unsubscribe" then unsubscribe(message["channel"].to_s, message["ref"])
          when "message" then receive_message(message)
          end
        end

        def subscribe(channel, last_id, ref)
          return send_json(type: "subscribed", channel: channel, ref: ref) if channels.include?(channel)
          return deny(channel, ref, "invalid_channel") unless subscribable?(channel)
          return deny(channel, ref, "too_many_channels") if channels.size >= Realtime.config.max_channels

          rule = Realtime.channels.authorize(channel, request) or return deny(channel, ref, "forbidden")
          tracked = track(channel, rule) # announce first: our own join isn't sent back to us
          Realtime.hub.subscribe(self, channel)
          send_json({ type: "subscribed", channel: channel, ref: ref,
                      presence: presence_list(channel, tracked) }.compact)
          messages, gap = Realtime.hub.replay([channel], last_id.to_s)
          messages.each { |message| deliver(message) }
          send_json(type: "gap", channel: channel) if gap
        end

        def unsubscribe(channel, ref)
          Realtime.hub.unsubscribe(self, channel)
          key = @presence.delete(channel)
          Realtime.presence.untrack(channel, key) if key
          send_json({ type: "unsubscribed", channel: channel, ref: ref }.compact)
        end

        # Presence channels: [key, meta] of an identified connection (tracked),
        # false for an anonymous one, nil for channels without presence.
        def track(channel, rule)
          return nil unless rule.presence

          key, meta = Realtime.identity_key(identity)
          return false unless key

          @presence[channel] = key
          Realtime.presence.track(channel, key, meta)
          [key, meta]
        end

        # Who's here, including this connection right away (its announcement
        # may still be travelling through the broker).
        def presence_list(channel, tracked)
          return nil if tracked.nil?

          list = Realtime.presence.list(channel)
          key, meta = tracked
          return list if !key || list.any? { |entry| entry["id"] == key }

          list + [{ "id" => key, "meta" => meta }]
        end

        def receive_message(message)
          channel = message["channel"].to_s
          ref = message["ref"]
          return reply_error(ref, "not_subscribed", "subscribe to #{channel} first") unless channels.include?(channel)

          handler, params = Realtime.channels.receiver(channel)
          return reply_error(ref, "no_handler", "#{channel} doesn't accept messages") unless handler

          incoming = Incoming.new(channel, message["event"].to_s, message["data"], params, self)
          result = handler.call(incoming)
          send_json({ type: "reply", ref: ref, ok: true, data: Serializer.render(result) }.compact) if ref
        rescue GemStack::Error => e
          reply_error(ref, e.code, e.message)
        rescue StandardError => e
          GemStack.logger.error("realtime: receive handler failed", channel: channel, error: e,
                                                                    backtrace: Array(e.backtrace).first(10))
          reply_error(ref, "internal_error", "the message couldn't be handled")
        end

        def subscribable?(channel) = CHANNEL_NAME.match?(channel) && channel != Presence::CHANNEL

        def deny(channel, ref, code) = send_json({ type: "denied", channel: channel, ref: ref, code: code }.compact)

        def reply_error(ref, code, message)
          return error(code, message) unless ref

          send_json(type: "reply", ref: ref, ok: false, error: { code: code, message: message })
        end

        def error(code, message, ref = nil)
          send_json({ type: "error", code: code, message: message, ref: ref }.compact)
        end

        def send_json(hash) = push(Codec.text(HTTP::JSONCodec.default.dump(hash)))

        def fail_connection(code, reason)
          GemStack.logger.debug("realtime: closing websocket", code: code, reason: reason)
          push(Codec.close(code, reason))
          close_after_flush
        end

        def silent? = monotonic - @last_seen > Realtime.config.heartbeat * 3

        # At most max_messages_per_second messages that run application code.
        def rate_limited?
          second = monotonic.floor
          @window = [second, 0] unless @window.first == second
          @window[1] += 1
          @window[1] > Realtime.config.max_messages_per_second
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # What a `receive` handler gets (config/channels.rb):
      #   message.channel, message.event, message.data, message.params (the * segments),
      #   message.identity (from `identify`), message.request (the WebSocket handshake).
      Incoming = Struct.new(:channel, :event, :data, :params, :connection) do
        def identity = connection.identity
        def request = connection.request
      end
    end
  end
end
