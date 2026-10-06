# frozen_string_literal: true

require "securerandom"
require "gemstack/core"
require "gemstack/schema"
require "gemstack/http"

module GemStack
  # Realtime between server and browsers (ARCHITECTURE §10, docs/realtime.md).
  #
  #   GemStack.broadcast("orders:#{order.id}", "order.updated", order)   # anywhere: controllers, jobs, console
  #
  #   // browser (frontend/lib/gemstack/realtime.ts)
  #   realtime.subscribe(`orders:${id}`, (event) => { ... })
  #   await realtime.send("rooms:1", "message.create", { body })        // handled by `receive`
  #
  # Transport: one WebSocket per browser tab on `<api_path>/realtime` (the
  # same origin as the API), held by an event loop off the server's request
  # threads. Subscriptions, client messages, presence and replay after
  # reconnects are multiplexed over it. Fan-out between processes goes through
  # a broker (PostgreSQL LISTEN/NOTIFY, or Redis). Channels are deny-by-default:
  # declare them in config/channels.rb. (GET without an Upgrade still serves the
  # deprecated Server-Sent Events stream for apps on the old client.)
  module Realtime
    class Config < Settings
      setting :path, default: -> { "#{GemStack.config.http.api_path}/realtime" }
      # :postgres (default when the app's database is PostgreSQL), :redis
      # (set it for MySQL/SQLite apps with more than one process, e.g. a jobs
      # worker broadcasting to the web server), :memory (single process; the
      # default otherwise), :test (default in tests), or a broker object.
      setting :broker, default: lambda {
        if GemStack.env.test? then :test
        elsif defined?(GemStack::DB) && GemStack::DB.type == :postgres then :postgres
        elsif ENV.fetch("REDIS_URL", "") != "" then :redis
        else :memory
        end
      }
      # Seconds between WebSocket pings (keeps proxies from closing idle
      # connections); a client silent for three heartbeats is disconnected.
      setting :heartbeat, default: 15
      # Recent events kept per process for Last-Event-ID replay after reconnects.
      setting :replay_size, default: 1_000
      setting :replay_ttl, default: 300
      setting :max_channels, default: 50
      # Largest WebSocket message a browser may send (bytes); larger closes with 1009.
      setting :max_message_size, default: 64 * 1024
      # Subscribe/unsubscribe/message requests per connection per second.
      setting :max_messages_per_second, default: 20
      # Threads that run channel authorization and `receive` handlers.
      setting :workers, default: 4
      # Origins allowed to open a WebSocket. nil: the API's own origin plus
      # config.http.cors.origins (browsers always send Origin; this blocks
      # cross-site WebSocket hijacking).
      setting :allowed_origins, default: nil
      # Seconds between presence refreshes; an entry lapses after three.
      setting :presence_interval, default: 15
      # A client that falls this far behind (bytes buffered) is disconnected.
      setting :max_buffer, default: 1024 * 1024
      # Reconnect delay the browser is told to use (ms).
      setting :retry_ms, default: 3_000
      setting :redis_url, default: -> { ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
      setting :redis_channel, default: -> { "gemstack:realtime:#{GemStack.config.name}" }
    end

    CHANNEL_NAME = /\A[A-Za-z0-9_\-.:]{1,200}\z/

    class InvalidChannel < BadRequest; end
    class PayloadTooLarge < Error; end

    # One broadcast.
    Message = Struct.new(:id, :channel, :event, :data) do
      def to_h = { id: id, channel: channel, event: event, data: data }
      def json = @json ||= HTTP::JSONCodec.default.dump(to_h)
      def sse = "id: #{id}\ndata: #{json}\n\n"
      # Encoded once per broadcast, however many connections receive it.
      def ws_frame = @ws_frame ||= WebSocket::Codec.text(%({"type":"event",#{json.delete_prefix("{")}))

      def self.from_json(string)
        hash = JSON.parse(string)
        new(hash["id"], hash["channel"], hash["event"], hash["data"])
      end
    end

    @mutex = Mutex.new

    class << self
      def config = GemStack.config.realtime

      def broker
        @broker || @mutex.synchronize { @broker ||= build_broker(config.broker) }
      end

      attr_writer :broker

      def hub
        @hub || @mutex.synchronize { @hub ||= Hub.new }
      end

      def channels
        @channels ||= Channels.new
      end

      def presence
        @presence || @mutex.synchronize { @presence ||= Presence.new }
      end

      # Who is on a presence channel right now, across processes:
      #   GemStack::Realtime.present_on("rooms:1") # => [{ "id" => "7", "meta" => { "name" => "Ada" } }]
      def present_on(channel) = presence.list(channel.to_s)

      # identify's result → [key, meta] for presence. A Hash needs an :id; a
      # model is keyed by #id; anything else by its string form.
      def identity_key(identity)
        case identity
        when nil then nil
        when Hash
          meta = identity.transform_keys(&:to_s)
          meta["id"].nil? ? nil : [meta["id"].to_s, meta]
        else
          id = identity.respond_to?(:id) ? identity.id : identity
          [id.to_s, { "id" => id.to_s }]
        end
      end

      def build_broker(setting)
        case setting
        when :postgres, "postgres" then Brokers::Postgres.new
        when :memory, "memory" then Brokers::Memory.new
        when :redis, "redis" then Brokers::Redis.new
        when :test, "test" then Brokers::Test.new
        else
          unless setting.respond_to?(:publish)
            raise ConfigurationError,
                  "a realtime broker must respond to #publish and #start"
          end

          setting
        end
      end

      def broadcast(channel, event, data = nil, context: {})
        channel = channel.to_s
        raise InvalidChannel, "invalid channel name #{channel.inspect}" unless CHANNEL_NAME.match?(channel)

        message = Message.new(next_id, channel, event.to_s, Serializer.render(data, context))
        broker.publish(message)
        GemStack.logger.debug("realtime.broadcast", channel: channel, event: message.event, id: message.id)
        message.id
      end

      # Starts delivering broker messages to this process's connections (idempotent).
      def listen!
        return true if @listening

        # Resolve these before locking: both lazily take the same mutex.
        active_broker = broker
        active_hub = hub
        @mutex.synchronize do
          @listening ||= begin
            active_broker.start { |message| active_hub.deliver(message) }
            true
          end
        end
      end

      def reset!
        @broker&.stop if @broker.respond_to?(:stop)
        @broker = nil
        @hub&.shutdown
        @hub = nil
        @presence&.stop
        @presence = nil
        @listening = nil
      end

      def next_id = "#{Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)}-#{SecureRandom.hex(4)}"
    end

    # config/channels.rb — what browsers may do, deny-by-default:
    #
    #   GemStack.channels do
    #     # Who is connecting (once per connection, from the handshake's cookies
    #     # or headers); nil for anonymous. A Hash ({ id:, name: }) is also the
    #     # presence metadata others see.
    #     identify { |request| current_user(request)&.then { |user| { id: user.id, name: user.name } } }
    #
    #     channel "announcements"                        # anyone may subscribe
    #     channel "orders:*" do |order_id, request|      # * = one segment, passed to the block
    #       Order.find_by(id: order_id)&.user_id == identity(request)&.fetch(:id)
    #     end
    #     channel "rooms:*", presence: true do |room_id, request| … end   # + who's here
    #
    #     # Messages browsers send with realtime.send(channel, event, data);
    #     # only to channels they're subscribed to. The return value is the reply.
    #     receive "rooms:*" do |message|
    #       post = Post.create!(room_id: message.params.first, body: message.data["body"],
    #                           user_id: message.identity[:id])
    #       GemStack.broadcast(message.channel, "post.created", post)
    #     end
    #   end
    class Channels
      Rule = Struct.new(:pattern, :regex, :block, :presence)
      IDENTITY = "gemstack.realtime.identity"

      def initialize
        @rules = []
        @receivers = []
        @identify = nil
      end

      def draw(&) = instance_exec(&)
      def rules = @rules.dup

      def clear
        @rules.clear
        @receivers.clear
        @identify = nil
      end

      def channel(pattern, presence: false, &block)
        @rules << Rule.new(pattern.to_s, compile(pattern), block, presence)
      end

      def receive(pattern, &block)
        raise ArgumentError, "receive needs a block" unless block

        @receivers << Rule.new(pattern.to_s, compile(pattern), block, false)
      end

      def identify(&block)
        @identify = block
      end

      # The identity of the connection a handshake request belongs to.
      def identity(request) = request.env[IDENTITY]

      def identify_request(request)
        request.env[IDENTITY] = @identify&.call(request)
      end

      # The rule allowing `name`, or nil (the first matching rule decides).
      def authorize(name, request)
        @rules.each do |rule|
          match = rule.regex.match(name) or next
          return rule if rule.block.nil? || rule.block.call(*match.captures, request)

          return nil
        end
        nil
      end

      def authorized?(name, request) = !authorize(name, request).nil?

      # [handler, params] for a message to `name`, or nil.
      def receiver(name)
        @receivers.each do |rule|
          match = rule.regex.match(name) or next
          return [rule.block, match.captures]
        end
        nil
      end

      private

      def compile(pattern)
        pattern = pattern.to_s
        unless pattern.split(":").all? { |part| part == "*" || CHANNEL_NAME.match?(part) }
          raise ArgumentError, "invalid channel pattern #{pattern.inspect}"
        end

        Regexp.new("\\A#{pattern.split(":").map { |part| part == "*" ? "([^:]+)" : Regexp.escape(part) }.join(":")}\\z")
      end
    end
  end

  class << self
    def broadcast(...) = Realtime.broadcast(...)

    # config/channels.rb: GemStack.channels { channel "announcements" }
    def channels(&)
      return Realtime.channels unless block_given?

      Realtime.channels.draw(&)
    end
  end
end

require_relative "realtime/websocket/codec"
require_relative "realtime/hub"
require_relative "realtime/presence"
require_relative "realtime/dispatcher"
require_relative "realtime/connection"
require_relative "realtime/streamer"
require_relative "realtime/websocket/connection"
require_relative "realtime/middleware"
require_relative "realtime/brokers/memory"
require_relative "realtime/brokers/test"
require_relative "realtime/brokers/postgres"
require_relative "realtime/brokers/redis"

GemStack::Config.namespace(:realtime, GemStack::Realtime::Config)

GemStack::Plugins.register(:realtime) do |app|
  next unless app.respond_to?(:root)

  stack = app.config.http.middleware
  unless stack.include?(GemStack::Realtime::Middleware)
    stack.insert_before(GemStack::HTTP::Middleware::HealthCheck, GemStack::Realtime::Middleware)
  end
  channels_file = app.root.join("config/channels.rb")
  load_channels = lambda do
    GemStack::Realtime.channels.clear
    load channels_file.to_s if channels_file.file?
  end
  load_channels.call
  app.on_reload(&load_channels) if app.respond_to?(:on_reload)
  app.on_shutdown { GemStack::Realtime.reset! } if app.respond_to?(:on_shutdown)
  # The broker's listener holds one database connection for the process.
  app.config.db.pool_size += 1 if app.config.realtime.broker.to_s == "postgres" && app.config.respond_to?(:db)
end
