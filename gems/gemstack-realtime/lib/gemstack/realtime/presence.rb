# frozen_string_literal: true

require "securerandom"

module GemStack
  module Realtime
    # Who is on a presence channel (`channel "rooms:*", presence: true`),
    # across every process.
    #
    # Each process counts its own connections per (channel, identity) and
    # announces the first join and the last leave through the broker, then
    # re-announces what it has every `presence_interval` seconds. Every process
    # (this one included) builds the same registry from those announcements;
    # an entry a process stops refreshing — it crashed or lost its broker —
    # expires after three intervals. Browsers get `presence.join`/`presence.leave`
    # when an identity appears or disappears (a second tab is not a new join).
    class Presence
      # Broker-only channel; browsers can't subscribe to it.
      CHANNEL = "gemstack:presence"
      # Keeps each announcement under the PostgreSQL broker's payload limit.
      BATCH = 50

      def initialize(interval: Realtime.config.presence_interval)
        @interval = interval
        @ttl = interval * 3
        @mutex = Mutex.new
        @local = {}   # [channel, key] => { count:, meta: }
        @state = {}   # channel => { key => { meta:, nodes: { node => expires_at } } }
      end

      # This process's id; a forked process (Puma worker) gets its own.
      def node
        return @node if @node_pid == Process.pid

        @node_pid = Process.pid
        @node = "#{Process.pid}-#{SecureRandom.hex(4)}"
      end

      # A connection identified as `key` subscribed to a presence channel.
      def track(channel, key, meta)
        first = @mutex.synchronize do
          entry = (@local[[channel, key]] ||= { count: 0, meta: meta })
          entry[:count] += 1
          entry[:count] == 1
        end
        start_timer
        announce("join", [[channel, key, meta]]) if first
      end

      def untrack(channel, key)
        last = @mutex.synchronize do
          entry = @local[[channel, key]] or return
          entry[:count] -= 1
          @local.delete([channel, key]) if entry[:count] <= 0
          entry[:count] <= 0
        end
        announce("leave", [[channel, key, nil]]) if last
      end

      # [{ "id" => key, "meta" => {...} }, ...] for a channel, across processes.
      def list(channel)
        @mutex.synchronize do
          (@state[channel] || {}).map { |key, entry| { "id" => key, "meta" => entry[:meta] } }
        end
      end

      # An announcement from the broker (from any process, this one included).
      def receive(message)
        node = message.data["node"]
        changes = @mutex.synchronize do
          message.data["entries"].filter_map do |channel, key, meta|
            if message.event == "leave"
              [:leave, channel, key, nil] if drop(channel, key, node)
            elsif add(channel, key, meta, node)
              [:join, channel, key, meta]
            end
          end
        end
        notify(changes)
      end

      # Re-announces this process's entries and expires everyone else's stale ones.
      def tick
        entries = @mutex.synchronize { @local.map { |(channel, key), entry| [channel, key, entry[:meta]] } }
        entries.each_slice(BATCH) { |batch| announce("refresh", batch) }
        notify(@mutex.synchronize { expire })
      end

      def stop
        @timer&.kill
        @timer = nil
      end

      private

      def add(channel, key, meta, node)
        entry = ((@state[channel] ||= {})[key] ||= { meta: meta, nodes: {} })
        fresh = entry[:nodes].empty?
        entry[:meta] = meta if meta
        entry[:nodes][node] = monotonic + @ttl
        fresh
      end

      def drop(channel, key, node)
        entry = @state.dig(channel, key) or return false
        entry[:nodes].delete(node)
        return false unless entry[:nodes].empty?

        remove(channel, key)
        true
      end

      def expire
        now = monotonic
        lapsed = @state.flat_map do |channel, keys|
          keys.filter_map do |key, entry|
            entry[:nodes].delete_if { |_, expires_at| expires_at < now }
            [:leave, channel, key, nil] if entry[:nodes].empty?
          end
        end
        lapsed.each { |_, channel, key, _| remove(channel, key) }
      end

      def remove(channel, key)
        @state[channel].delete(key)
        @state.delete(channel) if @state[channel].empty?
      end

      def notify(changes)
        changes.each do |op, channel, key, meta|
          event = Message.new(nil, channel, "presence.#{op}", { "id" => key, "meta" => meta }.compact)
          Realtime.hub.deliver_local(event)
        end
      end

      def announce(kind, entries)
        Realtime.broker.publish(Message.new(Realtime.next_id, CHANNEL, kind, { "node" => node, "entries" => entries }))
      rescue StandardError => e
        GemStack.logger.warn("realtime: presence announcement failed", error: e)
      end

      def start_timer
        return if @timer&.alive? # a forked process has no timer thread: it starts one

        @mutex.synchronize do
          @timer = Thread.new { timer_loop } unless @timer&.alive?
        end
      end

      def timer_loop
        loop do
          sleep @interval
          begin
            tick
          rescue StandardError => e
            GemStack.logger.warn("realtime: presence refresh failed", error: e)
          end
        end
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
