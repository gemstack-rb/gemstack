# frozen_string_literal: true

require "securerandom"

module GemStack
  module HTTP
    module Middleware
      # Assigns every request an id (env["gemstack.request_id"]), echoed in the
      # X-Request-Id response header and included in logs and error bodies.
      # An incoming X-Request-Id (e.g. from a load balancer) is reused when
      # trusted and well-formed.
      class RequestId
        VALID = /\A[A-Za-z0-9\-_.:]{1,128}\z/

        def initialize(app, config)
          @app = app
          @trust = config.trust_request_id
        end

        def call(env)
          incoming = env["HTTP_X_REQUEST_ID"]
          id = @trust && incoming&.match?(VALID) ? incoming : SecureRandom.uuid
          env[REQUEST_ID] = id
          status, headers, body = @app.call(env)
          headers["x-request-id"] = id
          [status, headers, body]
        end
      end
    end
  end
end
