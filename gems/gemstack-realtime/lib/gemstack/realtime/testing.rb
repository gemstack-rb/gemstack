# frozen_string_literal: true

require "gemstack/realtime"

module GemStack
  module Realtime
    # Test helpers (included into GemStack::TestCase by the generated test helper):
    #
    #   def test_updating_an_order_notifies_its_viewers
    #     patch_json "/api/orders/#{order.id}", { status: "shipped" }
    #
    #     assert_broadcast "orders:#{order.id}", "order.updated"
    #   end
    module Testing
      def self.included(base)
        base.class_eval do
          def before_setup
            super
            GemStack::Realtime.broker = GemStack::Realtime::Brokers::Test.new
          end
        end
      end

      def broadcasts = Realtime.broker.messages.reject { |m| m.channel == Presence::CHANNEL }

      # A broadcast on channel (optionally with this event name / data) happened.
      def assert_broadcast(channel, event = nil, data: nil)
        expected = data.nil? ? nil : as_json(data)
        matching = broadcasts.select do |m|
          m.channel == channel && (event.nil? || m.event == event.to_s) &&
            (expected.nil? || as_json(m.data) == expected)
        end
        assert(!matching.empty?,
               "Expected a broadcast on #{channel}#{" (#{event})" if event}; got #{broadcasts.map do |m|
                 [m.channel, m.event]
               end}")
      end

      # What a browser receives (string keys, decimals as strings, ...).
      def as_json(value) = JSON.parse(HTTP::JSONCodec.default.dump(value))

      def refute_broadcast(channel)
        assert(broadcasts.none? { |m| m.channel == channel }, "Expected no broadcast on #{channel}")
      end
    end
  end
end
