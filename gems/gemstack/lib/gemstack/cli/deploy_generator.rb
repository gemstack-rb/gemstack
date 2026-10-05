# frozen_string_literal: true

module GemStack
  class CLI < Thor
    # `gemstack generate deploy` — a Kamal setup: one Dockerfile image for every
    # process, config/deploy.yml (web, api and jobs roles; kamal-proxy routes /api
    # to Ruby and handles HTTPS; database accessories), .kamal/secrets,
    # bin/docker-entrypoint and .dockerignore. Nothing is deployed anywhere.
    class DeployGenerator < Generator
      def initialize(root:, output: $stdout, force: false)
        super(output: output, force: force)
        @root = root
      end

      KAMAL_GEM = %(gem "kamal", require: false, group: :development # bundle exec kamal deploy (config/deploy.yml)\n)
      # The image runs Next.js's standalone server (node frontend/server.js); the
      # Dockerfile asks for that build with GEMSTACK_NEXT_OUTPUT=standalone.
      STANDALONE = %(  output: process.env.GEMSTACK_NEXT_OUTPUT === "standalone" ? "standalone" : undefined,\n)

      def app_name = File.basename(@root).downcase.gsub(/[^a-z0-9_-]/, "-")
      # Kamal service and container names (also DNS names on the server).
      def service = app_name.tr("_", "-")
      def database_name = "#{app_name.tr("-", "_")}_production"
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
        packages = %w[libyaml-0-2 curl] +
                   { "postgresql" => ["libpq5"], "mysql2" => ["libmariadb3"] }.fetch(database_adapter, [])
        packages << "libstdc++6" if frontend? # Node.js
        packages.join(" ")
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
        @manifest = GenerationManifest.new(@root)
        template_files("deploy", override_root: @root).sort.each do |rel, source|
          content = File.read(source)
          content = render(content, source) if rel.end_with?(".tt")
          write_tracked(File.join(@root, output_path(rel.delete_suffix(".tt"))), content,
                        owner: "deploy:app", mode: File.stat(source).mode)
        end
        keep = File.join(@root, "vendor/.keep")
        write(keep, "") unless File.exist?(keep) # the Dockerfile copies vendor/ (e.g. vendor/cache)
        add_kamal_gem
        enable_standalone_frontend if frontend?
        warn_about_local_gems
        self
      ensure
        @manifest&.save
      end

      private

      def gemfile = @gemfile ||= File.read(File.join(@root, "Gemfile"))

      def add_kamal_gem
        path = File.join(@root, "Gemfile")
        return status("identical", path, "kamal") if gemfile.match?(/^\s*gem ["']kamal["']/)

        File.write(path, "#{gemfile.chomp}\n\n#{KAMAL_GEM}")
        status("gem", path, "kamal — run bundle install")
      end

      def enable_standalone_frontend
        path = File.join(@root, "frontend/next.config.ts")
        return unless File.file?(path)

        config = File.read(path)
        return status("identical", path, "standalone output") if config.include?("GEMSTACK_NEXT_OUTPUT")

        updated = config.sub(/^const nextConfig: NextConfig = \{\n/) { |open| open + STANDALONE }
        if updated == config
          return status("warning", path, "add `output: \"standalone\"` for the Docker build (docs/deployment.md)")
        end

        File.write(path, updated)
        status("update", path, "standalone output for the Docker build")
      end

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
