# frozen_string_literal: true

module GemStack
  module HTTP
    # `config.http` — every setting has a production-ready default.
    class Config < Settings
      # Where the API lives. Routes are declared relative to it, and the dev
      # gateway uses it to send traffic to Ruby. "" mounts the API at the root.
      setting :api_path, default: "/api"

      # Liveness endpoint answered by HealthCheck. nil disables it.
      setting :health_path, default: -> { "#{api_path}/health" }

      # Maximum request body size in bytes (413 beyond it).
      setting :max_body_size, default: 10 * 1024 * 1024

      # JSON codec: :json (stdlib, default), :oj, or any object responding to
      # dump(object) -> String and load(String) -> object.
      setting :json, default: :json

      # Maximum nesting depth accepted when parsing JSON request bodies.
      setting :json_max_nesting, default: 64

      # Include exception class, message and backtrace in 500 responses.
      # Never enable in production.
      setting :show_exceptions, default: -> { GemStack.env.local? }

      # Accept X-Request-Id from clients/proxies (validated) instead of
      # always generating one.
      setting :trust_request_id, default: true

      # Headers added to every response unless the response already sets them.
      setting :security_headers, default: {
        "x-content-type-options" => "nosniff",
        "x-frame-options" => "DENY",
        "referrer-policy" => "strict-origin-when-cross-origin",
        "cross-origin-opener-policy" => "same-origin",
        "content-security-policy" => "default-src 'none'; frame-ancestors 'none'"
      }

      # Strict-Transport-Security for HTTPS requests. nil disables.
      setting :hsts, default: -> { GemStack.env.production? ? "max-age=63072000; includeSubDomains" : nil }

      # Cross-origin access. Off by default: same-origin apps need none.
      namespace :cors do
        # Allowed origins: exact strings, Regexps, or "*".
        setting :origins, default: []
        setting :methods, default: %w[GET POST PUT PATCH DELETE OPTIONS]
        setting :headers, default: %w[content-type authorization x-request-id]
        setting :expose_headers, default: %w[x-request-id]
        setting :credentials, default: false
        setting :max_age, default: 600
      end

      # Response compression (Middleware::Compression).
      namespace :compression do
        setting :enabled, default: true
        # Bodies smaller than this are sent as they are (compression overhead
        # outweighs the savings on tiny responses).
        setting :min_size, default: 1024
        # Server preference; "br" is used only when the brotli gem is installed.
        setting :encodings, default: %w[br gzip]
        # Measured on varied JSON (docs/performance.md): gzip 4 costs half the
        # CPU of gzip 6 for ~2% larger output; Brotli 4 is smaller than gzip 4 and cheaper.
        setting :brotli_quality, default: 4
        setting :gzip_level, default: 4
      end

      # ETags for GET/HEAD responses and 304 Not Modified (Rack::ETag + Rack::ConditionalGet).
      setting :etags, default: true

      # Defaults for `paginate` in controllers.
      namespace :pagination do
        setting :per_page, default: 25
        setting :max_per_page, default: 100
      end

      # The middleware stack. Edit it with use / insert_before / insert_after /
      # swap / delete. Middleware receive this config and read it when the
      # application is built, so settings may be changed in any order.
      setting :middleware, default: -> { MiddlewareStack.default(self) }
    end
  end
end
