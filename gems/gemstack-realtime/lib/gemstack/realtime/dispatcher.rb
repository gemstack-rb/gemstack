# frozen_string_literal: true

module GemStack
  module Realtime
    # Runs application code for WebSocket connections — channel authorization
    # and `receive` handlers — on a small thread pool, never on the event loop,
    # so a slow query can't stall other connections. A connection's messages
    # are handled one at a time, in the order they arrived (Connection keeps
    # the inbox; the dispatcher only lends it a thread). Code runs under the
    # application's interlock, like a request, so it never overlaps a reload.
    class Dispatcher
      def self.instance
        @mutex ||= Mutex.new
        @instance || @mutex.synchronize { @instance ||= new }
      end

      def self.reset!
        @instance&.stop
        @instance = nil
      end

      def initialize(size: Realtime.config.workers)
        @queue = Queue.new
        @threads = Array.new(size) { Thread.new { work } }
      end

      # Asks a worker to run connection.process_inbox (or a callable).
      def schedule(connection) = @queue << connection

      def stop
        @queue.close
        @threads.each { |thread| thread.join(2) }
      end

      private

      # In an app (require "gemstack"), under its interlock so code reloading
      # waits; the realtime gem used on its own has no application.
      def with_application(&)
        GemStack.respond_to?(:application) ? GemStack.application.interlock.shared(&) : yield
      end

      def work
        while (connection = @queue.pop)
          begin
            with_application { connection.respond_to?(:process_inbox) ? connection.process_inbox : connection.call }
          rescue StandardError => e
            GemStack.logger.error("realtime: handler crashed", error: e, backtrace: Array(e.backtrace).first(10))
          end
        end
      end
    end
  end
end
