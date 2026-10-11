# frozen_string_literal: true

require "open3"

module GemStack
  class CLI < Thor
    # `gemstack deploy [KAMAL ARGS]` — Kamal with the app's root .env loaded,
    # so .kamal/secrets ($SECRET_KEY_BASE, $DATABASE_URL, …) and the frontend's
    # NEXT_PUBLIC_* build values come from the same file as everything else.
    # Kamal doesn't read .env itself.
    class DeployCommand
      # Production values first; .env.local is left out on purpose: on a
      # developer's machine it holds development overrides (a local
      # DATABASE_URL…) that must never reach production.
      ENV_FILES = %w[.env.production.local .env.production .env].freeze
      # Kamal builds the image from a clone of the last commit: uncommitted
      # changes wouldn't be deployed.
      BUILDS = %w[deploy setup redeploy build].freeze
      # What Kamal reads: a merge left unresolved in one of them (gemstack update)
      # breaks the deploy with a parse error that doesn't say why.
      CONFIG_FILES = %w[config/deploy.yml .kamal/secrets Dockerfile .dockerignore bin/docker-entrypoint].freeze
      CONFLICT = /^(?:<<<<<<<|>>>>>>>)(?: |$)/

      def initialize(root:, env: ENV, output: $stderr, exec: ->(*command, **opts) { Kernel.exec(*command, **opts) })
        @root = root
        @env = env
        @output = output
        @exec = exec
      end

      def run(args)
        unless File.file?(File.join(@root, "config/deploy.yml"))
          raise Thor::Error, "No config/deploy.yml: run `gemstack generate deploy` first (docs/deployment.md)"
        end

        args = ["deploy"] if args.empty?
        refuse_unresolved_merges!
        refuse_uncommitted_changes! if BUILDS.include?(args.first)
        load_env_files
        @exec.call("bundle", "exec", "kamal", *args, chdir: @root)
      end

      private

      def load_env_files
        files = ENV_FILES.map { |name| File.join(@root, name) }.select { |path| File.file?(path) }
        if files.empty?
          return @output.puts("gemstack deploy: no .env.production or .env; .kamal/secrets reads the environment")
        end

        loaded = Dotenv.load(files, env: @env)
        names = files.map { |path| File.basename(path) }.join(", ")
        @output.puts("gemstack deploy: #{loaded.size} settings from #{names} (the environment wins)")
      end

      def refuse_unresolved_merges!
        conflicts = CONFIG_FILES.filter_map do |rel|
          path = File.join(@root, rel)
          next unless File.file?(path)

          lines = File.foreach(path).with_index(1).filter_map { |line, number| number if line.match?(CONFLICT) }
          "#{rel} (line#{"s" if lines.size > 1} #{lines.join(", ")})" if lines.any?
        end
        return if conflicts.empty?

        raise Thor::Error, "Unresolved merge conflicts from `gemstack update` in #{conflicts.join("; ")}. In each " \
                           "block keep the side you want and delete the <<<<<<<, ======= and >>>>>>> lines."
      end

      def refuse_uncommitted_changes!
        changes, status = Open3.capture2("git", "-C", @root, "status", "--porcelain")
        return unless status.success? && !changes.strip.empty?

        raise Thor::Error, "Uncommitted changes: Kamal builds the image from the last commit, so they wouldn't " \
                           "be deployed. Commit (or stash) them first."
      rescue SystemCallError
        nil # no git: nothing to check
      end
    end

    desc "deploy [KAMAL ARGS]", "Deploy with Kamal, the root .env.production/.env loaded (or any Kamal command)"
    long_desc <<~DESC
      Runs `bundle exec kamal` with the app's root .env files loaded (.env.production.local,
      .env.production, .env — earlier files win, real environment variables win over all), so
      .kamal/secrets resolves its $VARIABLES from them. Without arguments it runs `kamal deploy`,
      and refuses when there are uncommitted changes (Kamal builds from the last commit).

        gemstack deploy                  # build, push and deploy the last commit
        gemstack deploy setup            # the first deploy: Docker, kamal-proxy, accessories
        gemstack deploy logs             # any Kamal command or alias: console, migrate, rollback VERSION…
    DESC
    stop_on_unknown_option! :deploy
    def deploy(*args)
      DeployCommand.new(root: Project.root!).run(args)
    end
  end
end
