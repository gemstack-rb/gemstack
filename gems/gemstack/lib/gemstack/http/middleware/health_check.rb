# frozen_string_literal: true

module GemStack
  module HTTP
    module Middleware
      # Answers GET/HEAD config.http.health_path with 200 {"status":"ok"}
      # without touching the router.
      class HealthCheck
        BODY = '{"status":"ok"}'

        def initialize(app, config)
          @app = app
          @path = config.health_path
        end

        def call(env)
          return @app.call(env) unless @path && env[Rack::PATH_INFO] == @path

          method = env[Rack::REQUEST_METHOD]
          return @app.call(env) unless %w[GET HEAD].include?(method)

          headers = { "content-type" => "application/json", "cache-control" => "no-store" }
          [200, headers, method == "HEAD" ? [] : [BODY]]
        end
      end
    end
  end
end
