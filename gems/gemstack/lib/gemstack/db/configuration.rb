# frozen_string_literal: true

require "erb"
require "uri"
require "yaml"

module GemStack
  module DB
    # Where the connection settings come from, first match wins:
    #
    #   1. config.db.url, set in config/app.rb or config/environments/*.rb
    #   2. DATABASE_URL (TEST_DATABASE_URL in the test environment)
    #   3. config/database.yml — the section for the current environment
    #   4. PostgreSQL on this machine, database <app>_<env> (apps without database.yml)
    #
    # config/database.yml works like Rails' (ERB allowed):
    #
    #   default: &default
    #     adapter: postgresql          # postgresql, mysql2, trilogy or sqlite3
    #     pool: <%= ENV.fetch("GEMSTACK_MAX_THREADS", 5) %>
    #   development:
    #     <<: *default
    #     database: shop_development
    #   test:
    #     <<: *default
    #     database: shop_test
    #   production:
    #     <<: *default
    #     url: <%= ENV["DATABASE_URL"] %>
    #
    # The result is a Hash for Sequel.connect: { adapter: "postgres", database:, host:, … }.
    module Configuration
      # Rails-style names (and URL schemes) → Sequel adapters.
      ADAPTERS = {
        "postgresql" => "postgres", "postgres" => "postgres", "postgis" => "postgres",
        "mysql2" => "mysql2", "mysql" => "mysql2", "trilogy" => "trilogy",
        "sqlite3" => "sqlite", "sqlite" => "sqlite"
      }.freeze
      # The gem each adapter needs in the application's Gemfile.
      DRIVER_GEMS = { "postgres" => "pg", "mysql2" => "mysql2", "trilogy" => "trilogy", "sqlite" => "sqlite3" }.freeze
      # database.yml keys with another name in Sequel.
      RENAMED = { "username" => :user, "pool" => :max_connections }.freeze
      # database.yml keys Rails uses that mean nothing to Sequel.
      IGNORED = %w[schema_search_path migrations_paths reaping_frequency idle_timeout checkout_timeout].freeze

      module_function

      def resolve(config: DB.config, env: GemStack.env, root: GemStack.config.root)
        return from_url(config.url, root: root).merge(source: "config.db.url") if config.url

        variable = env.test? ? "TEST_DATABASE_URL" : "DATABASE_URL"
        url = ENV.fetch(variable, "").strip
        yaml = yaml_settings(root, env)
        return from_url(url, root: root).merge(pool_from(yaml)).merge(source: variable) unless url.empty?
        return yaml.merge(source: "config/database.yml (#{env})") if yaml

        name = "#{GemStack.config.name.to_s.tr("-", "_")}_#{env}"
        { adapter: "postgres", database: name, source: "default (no config/database.yml)" }
      end

      # The section of config/database.yml for this environment, normalized; nil without the file.
      def yaml_settings(root, env)
        path = File.join(root.to_s, "config", "database.yml")
        return nil unless File.file?(path)

        data = YAML.safe_load(ERB.new(File.read(path)).result, aliases: true, filename: path) || {}
        section = data[env.to_s] or raise ConfigurationError, "config/database.yml has no #{env} section"
        raise ConfigurationError, "config/database.yml: #{env} must be a mapping" unless section.is_a?(Hash)

        from_hash(section, root: root)
      rescue Psych::Exception => e
        raise ConfigurationError, "config/database.yml: #{e.message}"
      end

      def from_hash(section, root:)
        url = section["url"].to_s.strip
        base = url.empty? ? {} : from_url(url, root: root)
        settings = section.each_with_object({}) do |(key, value), out|
          next if key == "url" || IGNORED.include?(key) || value.nil?

          out[RENAMED.fetch(key, key.to_sym)] = value
        end
        settings = base.merge(settings) { |_, from_url, from_keys| from_keys || from_url }
        settings[:adapter] = adapter!(settings[:adapter]) if settings[:adapter]
        raise ConfigurationError, "config/database.yml: set adapter (or url)" unless settings[:adapter]

        settings[:max_connections] = Integer(settings[:max_connections]) if settings[:max_connections]
        settings[:port] = Integer(settings[:port]) if settings[:port]
        sqlite_path(settings, root)
      end

      # postgres://user:pass@host:5432/name?sslmode=require, mysql2://…, trilogy://…,
      # sqlite3:db/development.sqlite3 (relative to the app), sqlite3:///abs/path.db, sqlite3::memory:
      def from_url(url, root:)
        scheme = url[/\A([a-z0-9+.-]+):/i, 1].to_s.downcase
        adapter = adapter!(scheme)
        if adapter == "sqlite"
          path = url.sub(/\A[^:]+:/, "").sub(%r{\A//}, "").sub(/\?.*\z/, "")
          return sqlite_path({ adapter: adapter, database: path }, root)
        end

        uri = URI.parse(url)
        settings = { adapter: adapter, host: uri.host, port: uri.port,
                     database: decode(uri.path.to_s.delete_prefix("/")), user: decode(uri.user),
                     password: decode(uri.password) }
        URI.decode_www_form(uri.query.to_s).each { |key, value| settings[key.to_sym] = value }
        settings.reject { |_, value| value.nil? || value == "" }
      rescue URI::InvalidURIError => e
        raise ConfigurationError, "invalid database URL: #{e.message}"
      end

      def adapter!(name)
        ADAPTERS.fetch(name.to_s.downcase) do
          raise ConfigurationError, "unsupported database adapter #{name.inspect} " \
                                    "(use postgresql, mysql2, trilogy or sqlite3)"
        end
      end

      def pool_from(yaml) = yaml && yaml[:max_connections] ? { max_connections: yaml[:max_connections] } : {}

      def sqlite_path(settings, root)
        return settings unless settings[:adapter] == "sqlite"

        database = settings[:database].to_s
        if database.empty?
          raise ConfigurationError,
                "sqlite3 needs a database file (e.g. database: db/development.sqlite3)"
        end

        settings[:database] = File.expand_path(database, root.to_s) unless database == ":memory:"
        settings
      end

      def decode(value) = value && URI.decode_www_form_component(value)

      # For logs and `gemstack doctor`: no passwords.
      def describe(settings)
        if settings[:adapter] == "sqlite"
          return "sqlite3 #{settings[:database].to_s.delete_prefix("#{GemStack.config.root}/")}"
        end

        host = settings[:host] || "localhost"
        user = settings[:user] ? "#{settings[:user]}@" : ""
        "#{settings[:adapter]}://#{user}#{host}#{":#{settings[:port]}" if settings[:port]}/#{settings[:database]}"
      end
    end
  end
end
