# frozen_string_literal: true

module GemStack
  module HTTP
    module Middleware
      # One structured log line per request, written when the response body is
      # closed so streamed responses are timed correctly:
      #
      #   INFO  GET /api/products status=200 ms=1.84 id=5f0c...
      #
      # Query strings are not logged (they often carry tokens).
      class RequestLogger
        def initialize(app, logger: nil)
          @app = app
          @logger = logger
        end

        def call(env)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          status, headers, body = @app.call(env)
          body = Rack::BodyProxy.new(body) { log(env, status, started) }
          [status, headers, body]
        end

        private

        def log(env, status, started)
          logger = @logger || GemStack.logger
          return unless logger.info?

          ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(2)
          severity = status >= 500 ? :error : :info
          logger.public_send(severity, "#{env[Rack::REQUEST_METHOD]} #{env[Rack::PATH_INFO]}",
                             status: status, ms: ms, id: env[REQUEST_ID])
        end
      end
    end
  end
end
