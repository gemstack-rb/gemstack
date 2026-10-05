# frozen_string_literal: true

require "bundler"
require "json"
require "net/http"

module GemStack
  class CLI < Thor
    # `gemstack update [VERSION]` — moves an app to the latest GemStack release
    # (or VERSION): rewrites every GemStack gem's constraint in the Gemfile to
    # "~> VERSION" and runs `bundle update` for them, together (the gems pin each
    # other's exact version). Apps that use a GemStack checkout (`path "…"`)
    # update the checkout instead.
    class UpdateGenerator
      # GemStack's gems, as an app's Gemfile lists them (gemstack-cli comes with gemstack).
      GEMS = %w[gemstack gemstack-auth gemstack-realtime].freeze
      VERSION_FORMAT = /\A\d+\.\d+\.\d+\z/
      LATEST_URL = "https://rubygems.org/api/v1/versions/gemstack/latest.json"

      # The first version whose `gemstack update --templates` exists.
      TEMPLATE_UPDATES_SINCE = Gem::Version.new("0.3.6")

      def initialize(root:, version: nil, output: $stdout, latest: nil, bundle: nil, templates: nil)
        @root = root
        @version = version
        @output = output
        @latest = latest || -> { latest_release }
        @bundle = bundle || ->(gems) { Bundler.with_unbundled_env { system("bundle", "update", *gems, chdir: @root) } }
        # Runs in the app's updated bundle, so the new version renders its own templates.
        # (The lockfile's version can be newer than the app's templates, so it isn't passed on.)
        @templates = templates || lambda {
          Bundler.with_unbundled_env { system("bundle", "exec", "gemstack", "update", "--templates", chdir: @root) }
        }
      end

      def run
        gemfile = read("Gemfile") or return failure("no Gemfile in #{@root}")
        return checkout(gemfile) if gemfile.match?(/^\s*path\s+["'][^"']+["']\s+do\b/)

        listed = GEMS.select { |name| gemfile.match?(gem_line(name)) }
        return failure(%(no `gem "gemstack"` in the Gemfile)) unless listed.include?("gemstack")

        target = @version || @latest.call
        return failure("#{target.inspect} is not a version (e.g. 0.3.5)") unless target.to_s.match?(VERSION_FORMAT)

        current = locked_version
        if current == target
          @output.puts("GemStack is already #{target}.")
          return true
        end
        if current && Gem::Version.new(target) < Gem::Version.new(current) && !@version
          @output.puts("GemStack #{current} is newer than the latest release (#{target}); nothing to do.")
          return true
        end

        update(gemfile, listed, current, target)
      end

      private

      def update(gemfile, listed, current, target)
        @output.puts("Updating GemStack #{current || "(not installed yet)"} → #{target}")
        updated = listed.reduce(gemfile) { |text, name| constrain(text, name, target) }
        File.write(File.join(@root, "Gemfile"), updated)
        listed.each { |name| @output.puts(%(  Gemfile  gem "#{name}", "~> #{target}")) }

        gems = (listed + ["gemstack-cli"]).uniq
        @output.puts("  run      bundle update #{gems.join(" ")}")
        bundled = begin
          @bundle.call(gems)
        rescue StandardError
          File.write(File.join(@root, "Gemfile"), gemfile) # never leave a half-done update behind
          raise
        end
        return bundle_failed(gemfile) unless bundled

        installed = locked_version
        unless installed == target
          return failure("bundle update finished but Gemfile.lock has gemstack #{installed.inspect}, not #{target}")
        end

        @output.puts("\nGemStack #{target} is installed.\n\n")
        update_templates(target)
        @output.puts(<<~DONE)

          Next:
            - read what changed: https://github.com/gemstack-rb/gemstack/blob/main/CHANGELOG.md
            - gemstack doctor
            - gemstack test
        DONE
        true
      end

      # `gem "name"` with any (or no) version requirement → `gem "name", "~> target"`,
      # keeping other options (require:, group:) and trailing comments.
      def constrain(text, name, target)
        text.gsub(/^(\s*gem\s+["']#{Regexp.escape(name)}["'])((?:\s*,\s*["'][^"']*["'])*)/) do
          %(#{Regexp.last_match(1)}, "~> #{target}")
        end
      end

      def update_templates(target)
        return if Gem::Version.new(target) < TEMPLATE_UPDATES_SINCE

        @templates.call || @output.puts("Templates weren't updated; run: gemstack update --templates")
      end

      def gem_line(name) = /^\s*gem\s+["']#{Regexp.escape(name)}["']/

      def checkout(gemfile)
        path = gemfile[/^\s*path\s+["']([^"']+)["']/, 1]
        @output.puts("This app uses GemStack from a checkout (#{path}): update it there, e.g.")
        @output.puts("  git -C #{path.delete_suffix("/gems")} pull")
        true
      end

      def bundle_failed(original)
        File.write(File.join(@root, "Gemfile"), original)
        failure("bundle update failed — the Gemfile is unchanged; see Bundler's message above")
      end

      def locked_version
        read("Gemfile.lock")&.[](/^    gemstack \(([^)]+)\)/, 1)
      end

      def latest_release
        response = Net::HTTP.get_response(URI(LATEST_URL))
        raise Thor::Error, "rubygems.org answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body).fetch("version")
      rescue SocketError, SystemCallError, Timeout::Error, JSON::ParserError => e
        raise Thor::Error, "Couldn't look up the latest GemStack on rubygems.org (#{e.class}). " \
                           "Pass a version: gemstack update 0.3.5"
      end

      def read(relative)
        path = File.join(@root, relative)
        File.read(path) if File.file?(path)
      end

      def failure(message)
        @output.puts("✗ #{message}")
        false
      end
    end
  end
end
