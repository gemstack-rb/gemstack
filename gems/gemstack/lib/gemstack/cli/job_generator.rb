# frozen_string_literal: true

module GemStack
  class CLI < Thor
    # `gemstack generate job SendWelcomeEmail [queue]`
    #
    # Writes app/jobs/<name>.rb and a test, and — the first time — the
    # migration for the gemstack_jobs table, so apps get the table only once
    # they actually use background jobs.
    class JobGenerator < Generator
      MIGRATION_GLOB = "db/migrations/*_create_gemstack_jobs.rb"

      attr_reader :class_name, :file_name, :queue_name

      def self.install_migration(root, output: $stdout, timestamp: nil)
        existing = Dir.glob(File.join(root, MIGRATION_GLOB)).first
        generator = new("Placeholder", root: root, output: output)
        return generator.status("identical", existing, "jobs table migration already present") if existing

        require "gemstack/jobs"
        stamp = timestamp || Generator.migration_timestamp(root)
        generator.write(File.join(root, "db/migrations/#{stamp}_create_gemstack_jobs.rb"), Jobs::Migration::SOURCE)
      end

      def initialize(name, root:, queue: nil, output: $stdout, force: false)
        super(output: output, force: force)
        @root = root
        base = Inflector.camelize(name.to_s).delete_suffix("Job")
        raise Thor::Error, "Invalid job name #{name.inspect}" unless base.match?(/\A[A-Z][A-Za-z0-9]*\z/)

        @class_name = name.to_s.end_with?("Job") ? Inflector.camelize(name.to_s) : base
        @file_name = Inflector.underscore(@class_name)
        @queue_name = queue
        Generator.check_constant!(@class_name, suggestion: "#{@class_name}Job") unless name == "Placeholder"
      end

      def run
        ensure_base_classes(@root, :job)
        template_files("job", override_root: @root).each do |rel, source|
          target = File.join(@root, rel.delete_suffix(".tt").gsub("%file_name%", file_name))
          write(target, render(File.read(source), source))
        end
        self.class.install_migration(@root, output: @output) if File.directory?(File.join(@root, "db"))
        self
      end
    end
  end
end
