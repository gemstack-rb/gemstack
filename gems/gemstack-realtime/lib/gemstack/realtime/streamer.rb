# frozen_string_literal: true

require "nio"

module GemStack
  module Realtime
    # A single event-loop thread (nio4r) that owns every open connection in
    # the process: it reads what clients send (WebSocket frames; for SSE only
    # the EOF of a disconnect), flushes buffered writes when sockets become
    # writable, and sends each transport's heartbeat. Request threads only
    # hand connections over, so 10,000 open connections cost no server threads.
    class Streamer
      def initialize(heartbeat: Realtime.config.heartbeat, hub: Realtime.hub)
        @heartbeat = heartbeat
        @hub = hub
        @selector = NIO::Selector.new
        @commands = Queue.new
        @monitors = {}
        @thread = nil
        @mutex = Mutex.new
      end

      def self.instance
        @mutex ||= Mutex.new
        @instance || @mutex.synchronize { @instance ||= new.start }
      end

      def self.reset!
        @instance&.stop
        @instance = nil
      end

      def start
        @running = true
        @thread = Thread.new { run }
        self
      end

      def stop
        @running = false
        @selector.wakeup
        @thread&.join(2)
        @monitors.each_key(&:close)
      end

      def size = @monitors.size

      # Called from request threads.
      def add(connection) = command(:add, connection)
      def want_write(connection) = command(:write, connection)
      def closed(connection) = command(:remove, connection)

      private

      def command(name, connection)
        @commands << [name, connection]
        @selector.wakeup
      end

      def run
        next_beat = monotonic + @heartbeat
        while @running
          @selector.select([next_beat - monotonic, 0.01].max) { |monitor| ready(monitor) }
          drain_commands
          next if monotonic < next_beat

          @monitors.each_key(&:heartbeat)
          next_beat = monotonic + @heartbeat
        end
      rescue StandardError => e
        GemStack.logger.error("realtime streamer crashed", error: e, backtrace: Array(e.backtrace).first(10))
        retry if @running
      end

      def drain_commands
        until @commands.empty?
          name, connection = @commands.pop
          case name
          when :add then register(connection)
          when :write then @monitors[connection]&.interests = :rw
          when :remove then deregister(connection)
          end
        end
      end

      def register(connection)
        return if connection.closed? || @monitors.key?(connection)

        monitor = @selector.register(connection.io, connection.pending? ? :rw : :r)
        monitor.value = connection
        @monitors[connection] = monitor
      rescue IOError, SystemCallError
        connection.close
      end

      def deregister(connection)
        monitor = @monitors.delete(connection) or return
        monitor.close
        @hub.remove(connection)
        connection.disconnected if connection.respond_to?(:disconnected)
      end

      def ready(monitor)
        connection = monitor.value
        if monitor.readable?
          data = connection.io.read_nonblock(16 * 1024, exception: false)
          return connection.close if data.nil? # EOF: the client went away

          # WebSocket frames; SSE clients send nothing after the request.
          connection.receive(data) if data.is_a?(String) && connection.respond_to?(:receive)
        end
        return unless monitor.writable?

        monitor.interests = :r if connection.flush
      rescue IOError, SystemCallError
        connection.close
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
