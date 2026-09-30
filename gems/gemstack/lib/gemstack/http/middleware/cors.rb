# frozen_string_literal: true

module GemStack
  module HTTP
    module Middleware
      # Cross-Origin Resource Sharing, driven by config.http.cors. It does
      # nothing until origins are configured — same-origin GemStack apps
      # (the default architecture) never need CORS.
      class Cors
        def initialize(app, config)
          @app = app
          cors = config.cors
          @origins = Array(cors.origins)
          @methods = cors.methods.map(&:upcase).join(", ")
          @headers = cors.headers.join(", ")
          @expose = cors.expose_headers.join(", ")
          @credentials = cors.credentials
          @max_age = cors.max_age.to_s
          return unless @credentials && @origins.include?("*")

          raise ConfigurationError, "CORS: credentials cannot be combined with the \"*\" origin"
        end

        def call(env)
          origin = env["HTTP_ORIGIN"]
          return @app.call(env) if @origins.empty? || origin.nil?

          allowed = allowed?(origin)
          return preflight(allowed ? origin : nil) if preflight?(env)

          status, headers, body = @app.call(env)
          vary(headers)
          apply(headers, origin) if allowed
          [status, headers, body]
        end

        private

        def preflight?(env)
          env[Rack::REQUEST_METHOD] == "OPTIONS" && env["HTTP_ACCESS_CONTROL_REQUEST_METHOD"]
        end

        def preflight(origin)
          headers = { "vary" => "Origin" }
          if origin
            apply(headers, origin)
            headers["access-control-allow-methods"] = @methods
            headers["access-control-allow-headers"] = @headers
            headers["access-control-max-age"] = @max_age
          end
          [204, headers, []]
        end

        def apply(headers, origin)
          headers["access-control-allow-origin"] = @origins.include?("*") ? "*" : origin
          headers["access-control-allow-credentials"] = "true" if @credentials
          headers["access-control-expose-headers"] = @expose unless @expose.empty?
        end

        def vary(headers)
          current = headers["vary"]
          headers["vary"] = current ? "#{current}, Origin" : "Origin" unless current&.include?("Origin")
        end

        def allowed?(origin)
          @origins.any? do |allowed|
            case allowed
            when "*" then true
            when Regexp then allowed.match?(origin)
            else allowed == origin
            end
          end
        end
      end
    end
  end
end
