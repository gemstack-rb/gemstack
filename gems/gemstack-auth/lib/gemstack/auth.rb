# frozen_string_literal: true

require "openssl"
require "securerandom"
require "gemstack/core"
require "gemstack/cache"
require "gemstack/http"
require "gemstack/db"
require "gemstack/mail"

module GemStack
  # Authentication: Argon2id passwords, database
  # sessions in an HttpOnly cookie for the Next.js frontend, and bearer API
  # tokens for scripts and other services. `gemstack add auth` generates the
  # tables, the User model, the controllers, the emails and the Next.js pages
  # that use this module — all of it application code you can change.
  module Auth
    class Config < Settings
      # The model that includes GemStack::Auth::User.
      setting :user_class, default: "User"
      # Sessions expire after this many seconds without use (sliding).
      setting :session_ttl, default: 30 * 24 * 3600
      # last_seen_at / expiry are updated at most this often (one UPDATE per session per interval).
      setting :session_touch_interval, default: 300
      # Secure cookies are HTTPS-only; local development runs on http://localhost.
      setting :cookie_secure, default: -> { !GemStack.env.local? }
      # The __Host- prefix makes browsers refuse the cookie unless it is Secure,
      # host-only and Path=/ — no subdomain can set or overwrite it.
      setting :cookie_name, default: -> { cookie_secure ? "__Host-session" : "gemstack_session" }
      setting :cookie_same_site, default: :lax
      setting :password_reset_ttl, default: 3600
      setting :email_verification_ttl, default: 3 * 24 * 3600
      # nil: API tokens don't expire (they can be revoked); or seconds.
      setting :api_token_ttl, default: nil
      setting :password_min_length, default: 12
      setting :password_max_length, default: 128
      # Argon2id cost: t = iterations, m = log2(memory KiB). 2 / 2^15 (32 MiB)
      # takes ~35 ms per hash on a 2024 laptop (OWASP's minimum is 19 MiB).
      setting :argon2_t_cost, default: -> { GemStack.env.test? ? 1 : 2 }
      setting :argon2_m_cost, default: -> { GemStack.env.test? ? 8 : 15 }
      # Other origins allowed to make cookie-authenticated, state-changing
      # requests (e.g. "https://admin.example.com"). Same-origin always works.
      setting :trusted_origins, default: []
      # Where the frontend lives, for links in emails.
      setting :app_url, default: -> { ENV.fetch("APP_URL", "http://localhost:#{ENV.fetch("PORT", "3000")}") }
    end

    class << self
      def config = GemStack.config.auth

      def user_class
        name = config.user_class
        name.is_a?(String) ? Object.const_get(name) : name
      end

      def db = DB.connection

      # The signed-in user of a Rack request — a Bearer API token or the session
      # cookie, like controllers' current_user — or nil. For code outside
      # controllers, e.g. config/channels.rb:
      #   identify { |request| GemStack::Auth.user_from(request)&.then { |u| { id: u.id } } }
      def user_from(request)
        if (token = request.get_header("HTTP_AUTHORIZATION").to_s[/\ABearer\s+(\S+)\z/i, 1])
          row = Tokens.find(token, purpose: "api") or return nil
          user_class[row[:user_id]]
        elsif (cookie = request.cookies[config.cookie_name])
          session = Sessions.find(cookie) or return nil
          user_class[session[:user_id]]
        end
      end

      # Deletes expired sessions and tokens; run it daily from a job.
      def cleanup!
        now = Time.now
        { sessions: db[:sessions].where { expires_at <= now }.delete,
          auth_tokens: db[:auth_tokens].exclude(expires_at: nil).where { expires_at <= now }.delete }
      end

      # A link into the frontend: Auth.url("/reset-password", token: t)
      def url(path, **query)
        base = config.app_url.to_s.chomp("/")
        query.empty? ? "#{base}#{path}" : "#{base}#{path}?#{URI.encode_www_form(query)}"
      end
    end

    # Opaque random tokens; only their SHA-256 digests are stored, so a
    # database leak doesn't hand out working sessions or reset links.
    module Token
      def self.generate(prefix = "") = "#{prefix}#{SecureRandom.urlsafe_base64(32)}"
      def self.digest(token) = OpenSSL::Digest::SHA256.hexdigest(token.to_s)

      # Tokens are 43–50 characters; anything else is not worth a query.
      def self.plausible?(token) = token.is_a?(String) && token.bytesize.between?(20, 200)
    end
  end
end

require_relative "auth/password"
require_relative "auth/sessions"
require_relative "auth/tokens"
require_relative "auth/user"
require_relative "auth/rate_limit"
require_relative "auth/controller"
require_relative "policy"

GemStack::Config.namespace(:auth, GemStack::Auth::Config)
