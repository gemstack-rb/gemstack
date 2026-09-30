# frozen_string_literal: true

module GemStack
  module Realtime
    module Brokers
      # Fan-out between processes with PostgreSQL LISTEN/NOTIFY (the default
      # with gemstack/db): a broadcast from a job worker reaches browsers
      # connected to any API process, with no extra infrastructure.
      #
      # NOTIFY is transactional, so a broadcast inside a transaction is
      # delivered only if — and when — it commits. Payloads are limited to
      # ~8 KB by PostgreSQL: broadcast what changed (ids, small records) and
      # let clients refetch larger data.
      class Postgres
        CHANNEL = "gemstack_realtime"
        MAX_PAYLOAD = 7_900

        def initialize(db: nil)
          @db = db
        end

        def db
          @db || begin
            require "gemstack/db"
            GemStack::DB.connection
          end
        end

        def publish(message)
          payload = message.json
          if payload.bytesize > MAX_PAYLOAD
            raise PayloadTooLarge, "realtime payload is #{payload.bytesize} bytes; the PostgreSQL broker allows " \
                                   "#{MAX_PAYLOAD}. Broadcast ids or a smaller serializer, or use the Redis broker."
          end
          db.notify(CHANNEL, payload: payload)
        end

        # Listens on a dedicated connection in a background thread.
        def start(&on_message)
          @running = true
          ready = Queue.new
          @thread = Thread.new { listen(on_message, ready) }
          ready.pop(timeout: 5)
          self
        end

        def stop
          @running = false
          @thread&.join(2)
        end

        private

        def listen(on_message, ready)
          while @running
            begin
              db.listen(CHANNEL, loop: ->(_conn) { throw :stop unless @running }, timeout: 1,
                                 after_listen: ->(_conn) { ready << true }) do |_channel, _pid, payload|
                deliver(on_message, payload)
              end
            rescue Sequel::Error => e
              GemStack.logger.warn("realtime: LISTEN failed, retrying", error: e.message)
              sleep 1
            end
          end
        end

        def deliver(on_message, payload)
          on_message.call(Message.from_json(payload))
        rescue StandardError => e
          GemStack.logger.error("realtime: delivery failed", error: e)
        end
      end
    end
  end
end
