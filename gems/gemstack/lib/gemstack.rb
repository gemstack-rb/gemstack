# frozen_string_literal: true

require "gemstack/core"
require "gemstack/cache"
require "gemstack/http"
require "gemstack/dev"
require "gemstack/contract" # /api/docs in development; `gemstack contract`
require_relative "gemstack/interlock"
require_relative "gemstack/reloader"
require_relative "gemstack/application"

module GemStack
  class Config
    # Reload app/ code and routes between requests when files change.
    setting :reload_code, default: -> { GemStack.env.development? }
    # Load all application code at boot (faster first requests, copy-on-write
    # friendly with Puma workers).
    setting :eager_load, default: -> { !GemStack.env.local? }
    # Extra directories to autoload, relative to the root (e.g. ["lib"]).
    setting :autoload_paths, default: []
    # Ruby JIT enabled at boot: :yjit (production default, measured fastest),
    # :zjit (Ruby 4's newer JIT, opt-in), or nil. GEMSTACK_JIT=yjit|zjit|off overrides.
    setting :jit, default: lambda {
      case ENV.fetch("GEMSTACK_JIT", nil)
      when "off", "none", "" then nil
      when String then ENV["GEMSTACK_JIT"].to_sym
      else GemStack.env.production? ? :yjit : nil
      end
    }
  end

  # Short names for application code:
  #   class ApplicationController < GemStack::Controller
  Controller = HTTP::Controller
  Params = HTTP::Params
  # GemStack::Schema, GemStack::Serializer and GemStack::Types come from gemstack/schema.

  class << self
    def application
      @application ||= Application.new(config: config)
    end

    attr_writer :application

    def boot! = application.boot!

    # config/routes.rb:
    #   GemStack.routes do
    #     resources :products
    #   end
    def routes(&)
      return application.routes unless block_given?

      application.draw_routes(&)
    end

    alias reset_core! reset!

    def reset!
      reset_core!
      @application = nil
    end
  end
end
