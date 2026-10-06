# frozen_string_literal: true

module GemStack
  module Realtime
    # One browser connection on a hijacked socket — the Server-Sent Events
    # stream; WebSocket::Connection builds on it. #push never blocks:
    # bytes the socket can't take yet are buffered and flushed by the
    # Streamer when it becomes writable. A client more than max_buffer bytes
    # behind is disconnected (it reconnects and replays or refetches).
    class Connection
      attr_reader :io, :channels, :identity

      def initialize(io, channels, streamer:, identity: nil, max_buffer: Realtime.config.max_buffer)
        @io = io
        @identity = identity
        @presence = {} # channel => identity key
        @channels = Set.new(channels)
        @streamer = streamer
        @max_buffer = max_buffer
        @buffer = String.new(encoding: Encoding::BINARY)
        @mutex = Mutex.new
        @closed = false
      end

      def closed? = @closed
      def pending? = @mutex.synchronize { !@buffer.empty? }

      # Transport hooks: how a broadcast and a keep-alive are written. The
      # keep-alive is a data event (comments are invisible to EventSource), so
      # the browser can tell a quiet connection from a dead one.
      def deliver(message) = push(message.sse)
      def heartbeat = push(PING)
      PING = "data: #{JSON.generate(id: nil, channel: nil, event: "gemstack.ping", data: nil)}\n\n".freeze

      # SSE presence: the stream's presence channels, tracked while it's open.
      def track_presence(channel)
        key, meta = Realtime.identity_key(identity)
        return [] unless key

        @presence[channel] = key
        Realtime.presence.track(channel, key, meta)
        list = Realtime.presence.list(channel)
        list.any? { |entry| entry["id"] == key } ? list : list + [{ "id" => key, "meta" => meta }]
      end

      # Called by the Streamer once the socket is gone.
      def disconnected
        @presence.each { |channel, key| Realtime.presence.untrack_later(channel, key) }
        @presence.clear
      end

      def push(bytes)
        wants_write = @mutex.synchronize do
          return false if @closed

          @buffer << bytes.b
          if @buffer.bytesize > @max_buffer
            GemStack.logger.warn("realtime: slow client disconnected", buffered: @buffer.bytesize)
            close_locked
            return false
          end
          !flush_locked
        end
        @streamer.want_write(self) if wants_write
        true
      end

      # Writes as much as the socket accepts. Returns true when fully flushed
      # (and closes the socket if #close_after_flush asked for it).
      def flush
        @mutex.synchronize do
          return true if @closed

          flushed = flush_locked
          close_locked if flushed && @close_after_flush
          flushed
        end
      end

      # Sends what's buffered, then closes (e.g. after a WebSocket close frame).
      def close_after_flush
        done = @mutex.synchronize do
          @close_after_flush = true
          flush_locked.tap { |flushed| close_locked if flushed }
        end
        @streamer.want_write(self) unless done
      end

      def close
        @mutex.synchronize { close_locked }
      end

      private

      def flush_locked
        until @buffer.empty?
          written = @io.write_nonblock(@buffer, exception: false)
          return false if written == :wait_writable

          @buffer = @buffer.byteslice(written, @buffer.bytesize) || String.new(encoding: Encoding::BINARY)
        end
        true
      rescue IOError, SystemCallError
        close_locked
        true
      end

      def close_locked
        return if @closed

        @closed = true
        @buffer.clear
        @io.close unless @io.closed?
        @streamer.closed(self)
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
