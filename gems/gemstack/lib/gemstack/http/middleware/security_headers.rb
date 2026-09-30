# frozen_string_literal: true

module GemStack
  module HTTP
    module Middleware
      # Adds config.http.security_headers to responses that don't already set
      # them, plus Strict-Transport-Security on HTTPS requests when
      # config.http.hsts is set (production by default).
      class SecurityHeaders
        def initialize(app, config)
          @app = app
          @headers = config.security_headers.transform_keys { |key| key.to_s.downcase }.freeze
          @hsts = config.hsts
        end

        def call(env)
          status, headers, body = @app.call(env)
          @headers.each { |key, value| headers[key] = value unless headers.key?(key) }
          headers["strict-transport-security"] ||= @hsts if @hsts && https?(env)
          [status, headers, body]
        end

        private

        def https?(env)
          env[Rack::RACK_URL_SCHEME] == "https" || env["HTTP_X_FORWARDED_PROTO"]&.start_with?("https")
        end
      end
    end
  end
end
