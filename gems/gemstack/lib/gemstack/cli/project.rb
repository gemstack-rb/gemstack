# frozen_string_literal: true

module GemStack
  class CLI < Thor
    # Locates the GemStack application the CLI is run from and makes sure
    # commands run inside that application's bundle, so the app's own
    # GemStack version and gems are used (like a binstub would).
    module Project
      MARKER = "config/app.rb"

      module_function

      def root(start = Dir.pwd)
        dir = File.expand_path(start)
        loop do
          return dir if File.file?(File.join(dir, MARKER)) && File.file?(File.join(dir, "Gemfile"))

          parent = File.dirname(dir)
          return nil if parent == dir

          dir = parent
        end
      end

      def root!
        root || abort("Not inside a GemStack application (no #{MARKER} found). Create one with `gemstack new myapp`.")
      end

      def in_bundle?(app_root)
        gemfile = ENV.fetch("BUNDLE_GEMFILE", nil)
        gemfile && File.expand_path(gemfile) == File.join(app_root, "Gemfile") && defined?(Bundler)
      end

      # Re-executes the current command under `bundle exec` unless the app's
      # bundle is already active, then chdirs to the app root.
      def ensure_bundle!(argv)
        app_root = root!
        unless in_bundle?(app_root)
          Dir.chdir(app_root)
          ENV["BUNDLE_GEMFILE"] = File.join(app_root, "Gemfile")
          exec("bundle", "exec", "gemstack", *argv)
        end
        Dir.chdir(app_root)
        app_root
      end

      # Loads config/app.rb (configuration + gems) without booting the app.
      def load_config!(app_root)
        require File.join(app_root, MARKER)
      end
    end
  end
end
