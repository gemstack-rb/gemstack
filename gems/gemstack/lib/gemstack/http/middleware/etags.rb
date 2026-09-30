# frozen_string_literal: true

module GemStack
  module HTTP
    module Middleware
      # ETags and conditional GET, using Rack's own middleware: Rack::ETag adds
      # a weak ETag (SHA-256 of the body) to buffered 200/201 responses that
      # don't set one, and Rack::ConditionalGet answers matching
      # If-None-Match / If-Modified-Since requests with 304 and no body.
      # Controllers can set ETags themselves (see Controller#stale?).
      #
      # Responses without Cache-Control get Rack's
      # "max-age=0, private, must-revalidate": clients may keep a copy but
      # must revalidate it — the safe default for API data.
      class ETags
        def initialize(app, config)
          @app = config.etags ? Rack::ConditionalGet.new(Rack::ETag.new(app)) : app
        end

        def call(env) = @app.call(env)
      end
    end
  end
end
