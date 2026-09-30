# frozen_string_literal: true

require "bundler/setup"
require "gemstack"
require "gemstack/db"   # models and migrations (PostgreSQL: DATABASE_URL, or shop_<env> on this machine)
require "gemstack/jobs" # background jobs

# Sets the application root and loads .env files (development/test).
GemStack.setup(root: File.expand_path("..", __dir__))

# Require the gems listed in the Gemfile for the current environment.
Bundler.require(:default, GemStack.env.to_sym)

GemStack.configure do |config|
  config.name = "shop"

  # Everything below is optional — these are the defaults. See docs/configuration.md.
  #
  # config.http.api_path = "/api"                  # where the API lives (routes are relative to it)
  # config.http.max_body_size = 10 * 1024 * 1024   # bytes; larger requests get 413
  # config.http.json = :json                       # or :oj (add gem "oj"), or your own codec
  # config.http.cors.origins = []                  # only for frontends on another domain
  # config.http.middleware.use MyMiddleware        # add / insert_before / swap / delete
  # config.logger.level = :debug
  # config.filter_parameters += %w[iban]           # masked in logs
  #
  # config.db.url = ENV["DATABASE_URL"]            # default: postgres:///<name>_<env> (TEST_DATABASE_URL in test)
  # config.db.pool_size = 5                        # default: GEMSTACK_MAX_THREADS (one per Puma thread)
  # config.db.statement_timeout = 5_000            # ms
end
