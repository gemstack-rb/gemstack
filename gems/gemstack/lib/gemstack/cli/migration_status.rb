# frozen_string_literal: true

require "open3"

module GemStack
  class CLI < Thor
    # Read migration history in the app's bundle without booting its models.
    # Unknown state is never treated as permission to delete a migration.
    class MigrationStatus
      PROBE = <<~RUBY
        require "json"
        require File.expand_path("config/app.rb")
        abort "Database module unavailable" unless defined?(GemStack::DB)
        settings = GemStack::DB.settings.except(:source).merge(GemStack::DB.config.options)
        if settings[:adapter] == "sqlite"
          abort "In-memory database has no persistent history" if settings[:database] == ":memory:"
          unless File.exist?(settings[:database])
            puts JSON.generate([])
            exit
          end
          settings[:readonly] = true
        end
        Sequel.connect(**settings) do |db|
          puts JSON.generate(GemStack::DB::Migrator.new(db).applied)
        end
      RUBY

      def initialize(root, environment: nil)
        @root = root
        @environment = environment || ENV.fetch("GEMSTACK_ENV", "development")
      end

      def applied
        return unless File.file?(File.join(@root, "config/app.rb"))

        run = lambda do
          Open3.capture3({ "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "true",
                           "GEMSTACK_ENV" => @environment },
                         "bundle", "exec", "ruby", "-e", PROBE, chdir: @root)
        end
        output, _, status = defined?(Bundler) ? Bundler.with_unbundled_env(&run) : run.call
        return unless status.success?

        files = JSON.parse(output.lines.last.to_s)
        files if files.is_a?(Array) && files.all?(String)
      rescue JSON::ParserError, SystemCallError
        nil
      end
    end
  end
end
