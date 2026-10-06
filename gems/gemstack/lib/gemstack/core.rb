# frozen_string_literal: true

require "openssl"
require "securerandom"
require "fileutils"
require_relative "version"
require_relative "settings"
require_relative "environment"
require_relative "dotenv"
require_relative "errors"
require_relative "error_mapping"
require_relative "logger"
require_relative "inflector"
require_relative "plugins"

module GemStack
  # Root configuration. Modules add namespaces to it:
  #   GemStack::Config.namespace(:http, GemStack::HTTP::Config)
  class Config < Settings
    setting :name, default: -> { File.basename(root) }
    setting :root, default: -> { Dir.pwd }

    # .env files loaded at boot from the app root, in every environment (one
    # .env for the API and the frontend: next.config.ts reads the same files).
    # Earlier files win; real ENV always wins. Missing files are skipped, so
    # production containers configured through ENV are unaffected.
    setting :env_files, default: lambda {
      env = GemStack.env
      [".env.#{env}.local", ".env.local", ".env.#{env}", ".env"]
    }

    # Root secret for signatures (storage URLs, derived keys). Production must
    # set SECRET_KEY_BASE; development/test generate one in tmp/ (git-ignored).
    setting :secret_key_base, default: lambda {
      ENV.fetch("SECRET_KEY_BASE", nil) || (GemStack.env.local? ? GemStack.send(:local_secret) : nil)
    }

    # Keys (substring, case-insensitive) masked in logs and error output.
    setting :filter_parameters, default: %w[password passwd secret token api_key apikey authorization cookie
                                            credit_card card_number cvv ssn private_key]

    namespace :logger do
      setting :level, default: -> { ENV.fetch("GEMSTACK_LOG_LEVEL") { GemStack.env.production? ? "info" : "debug" } }
      setting :format, default: -> { GemStack.env.local? ? :pretty : :json }
      # Test logs are discarded unless GEMSTACK_LOG_LEVEL is set explicitly.
      setting :output, default: -> { GemStack.env.test? && !ENV["GEMSTACK_LOG_LEVEL"] ? nil : $stdout }
      # nil = colour when output is a terminal. `gemstack dev` sets
      # GEMSTACK_LOG_COLOR=1 because child output goes through a pipe.
      setting :color, default: -> { ENV["GEMSTACK_LOG_COLOR"]&.then { |v| v == "1" } }
    end
  end

  class << self
    def config
      @config ||= Config.new
    end

    def configure
      yield config
      config
    end

    def env
      @env ||= Environment.detect
    end

    def env=(name)
      @env = name.is_a?(Environment) ? name : Environment.new(name)
    end

    def root
      Pathname.new(config.root)
    end

    # First call in config/app.rb: sets the application root and loads .env
    # files before anything reads configuration or ENV.
    def setup(root:)
      config.root = root.to_s
      load_env_files!
      self
    end

    # Idempotent; real ENV variables are never overwritten.
    def load_env_files!
      files = config.env_files.map { |file| File.expand_path(file, config.root) }
      return if @loaded_env_files == files

      Dotenv.load(files)
      @loaded_env_files = files
    end

    def logger
      @logger ||= begin
        settings = config.logger
        Logger.new(settings.output, level: settings.level, format: settings.format,
                                    filter: config.filter_parameters, color: settings.color)
      end
    end

    attr_writer :logger

    # A 32-byte key for one purpose, derived from secret_key_base, so a key
    # leaked for one use (e.g. storage URLs) can't sign anything else.
    def key_for(purpose)
      secret = config.secret_key_base
      if secret.to_s.empty?
        raise ConfigurationError,
              "SECRET_KEY_BASE is not set (generate one with: openssl rand -hex 64)"
      end

      OpenSSL::HMAC.digest("SHA256", secret, "gemstack:#{purpose}")
    end

    # Forget all process-level state. Intended for tests.
    def reset!
      @config = nil
      @env = nil
      @logger = nil
      @loaded_env_files = nil
    end

    private

    def local_secret
      path = File.join(config.root, "tmp", "#{env}_secret")
      return File.read(path).strip if File.file?(path)

      FileUtils.mkdir_p(File.dirname(path))
      SecureRandom.hex(64).tap { |secret| File.write(path, secret, perm: 0o600) }
    end
  end
end
