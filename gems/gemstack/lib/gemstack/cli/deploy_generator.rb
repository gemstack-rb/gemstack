# frozen_string_literal: true

module GemStack
  class CLI < Thor
    # `gemstack generate deploy` — Dockerfile (api + web targets), compose.yaml
    # (Postgres, migrations, API, jobs, Next.js, Caddy), Caddyfile, Procfile and
    # .dockerignore. Nothing is deployed anywhere.
    class DeployGenerator < Generator
      def initialize(root:, output: $stdout, force: false)
        super(output: output, force: force)
        @root = root
      end

      def app_name = File.basename(@root).downcase.gsub(/[^a-z0-9_-]/, "-")
      def frontend? = File.file?(File.join(@root, "frontend/package.json"))

      # A worker process is needed for background jobs (and auth's emails).
      def jobs?
        return true if Generator.uses?(@root, :auth)

        Generator.uses?(@root, :jobs) && Generator.background_work?(@root)
      end

      def mail? = Generator.uses?(@root, :mail) || Generator.uses?(@root, :auth)
      def database? = Generator.uses?(@root, :db)
      def realtime? = Generator.uses?(@root, :realtime)

      # From config/database.yml (production, else the first adapter listed);
      # apps without one use PostgreSQL, GemStack's original default.
      def database_adapter
        path = File.join(@root, "config/database.yml")
        return "postgresql" unless File.file?(path)

        text = File.read(path)
        production = text[/^production:.*?(?=^\S|\z)/m].to_s
        (production[/^\s+adapter:\s*(\w+)/, 1] || text[/^\s+adapter:\s*(\w+)/, 1] || "postgresql")
          .then { |name| { "postgres" => "postgresql", "sqlite" => "sqlite3", "mysql" => "mysql2" }.fetch(name, name) }
      end

      def sqlite? = database_adapter == "sqlite3"
      def mysql? = %w[mysql2 trilogy].include?(database_adapter)
      def postgresql? = database_adapter == "postgresql"
      # A Redis for realtime fan-out when the database can't do it (PostgreSQL uses NOTIFY).
      def redis? = realtime? && !postgresql?

      def build_packages
        (%w[build-essential libyaml-dev
            git] + { "postgresql" => ["libpq-dev"], "mysql2" => ["default-libmysqlclient-dev"] }.fetch(database_adapter,
                                                                                                       [])).join(" ")
      end

      def runtime_packages
        (%w[libyaml-0-2
            curl] + { "postgresql" => ["libpq5"], "mysql2" => ["libmariadb3"] }.fetch(database_adapter, [])).join(" ")
      end

      def database_url
        case database_adapter
        when "sqlite3" then "sqlite3:/data/production.sqlite3"
        when "postgresql" then "postgres://app:${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}@db:5432/app"
        else "#{database_adapter}://app:${MYSQL_PASSWORD:?set MYSQL_PASSWORD}@db:3306/app"
        end
      end

      def ruby_version
        pinned = File.file?(File.join(@root, ".ruby-version")) && File.read(File.join(@root, ".ruby-version")).strip
        pinned && !pinned.empty? ? pinned.delete_prefix("ruby-") : RUBY_VERSION
      end

      def node_version
        tools = File.join(@root, ".tool-versions")
        pinned = File.file?(tools) && File.read(tools)[/^nodejs\s+(\d+)/, 1]
        pinned || "22"
      end

      def run
        template_files("deploy", override_root: @root).sort.each do |rel, source|
          content = File.read(source)
          content = render(content, source) if rel.end_with?(".tt")
          write(File.join(@root, output_path(rel.delete_suffix(".tt"))), content)
        end
        keep = File.join(@root, "vendor/.keep")
        write(keep, "") unless File.exist?(keep) # the Dockerfile copies vendor/ (e.g. vendor/cache)
        warn_about_local_gems
        self
      end

      private

      def gemfile = @gemfile ||= File.read(File.join(@root, "Gemfile"))

      # Apps generated from a GemStack checkout point at it with an absolute
      # path, which doesn't exist inside the image.
      def warn_about_local_gems
        return unless gemfile.match?(/^path "/)

        status("warning", "Gemfile", "GemStack comes from a local path the image can't see — " \
                                     "run `bundle cache --all` (vendor/cache) or use released gems")
      end
    end
  end
end
