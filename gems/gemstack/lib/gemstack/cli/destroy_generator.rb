# frozen_string_literal: true

require "ripper"

module GemStack
  class CLI < Thor
    # Plans the complete operation before changing anything. Only migrations
    # confirmed pending in the selected environment are eligible for removal.
    class DestroyGenerator < Generator
      KINDS = %w[model controller resource].freeze
      SHARED = (Generator::BASE_CLASSES.values + %w[
        app/controllers/application_controller.rb test/test_helper.rb
        frontend/lib/format.ts frontend/lib/gemstack/client.ts
        frontend/app/layout.tsx frontend/app/providers.tsx frontend/app/globals.css
      ]).freeze

      def self.configure(cli)
        cli.method_option :dry_run, type: :boolean, default: false, desc: "Preview without changing files or contracts"
        cli.method_option :yes, type: :boolean, default: false, desc: "Confirm removal without an interactive prompt"
        cli.method_option :force, type: :boolean, default: false, desc: "Allow removing modified, tracked files"
        cli.method_option :remove_migrations, type: :boolean, default: false,
                                              desc: "Remove pending migrations even if committed to Git"
        cli.method_option :skip_contract, type: :boolean, default: false, desc: "Don't regenerate the API contract"
      end

      def self.invoke(kind, name, cli:)
        options = cli.options
        root = Project.root!
        removal = new(
          kind,
          name,
          root: root,
          dry_run: options[:dry_run],
          force: options[:force],
          remove_migrations: options[:remove_migrations],
          environment: options[:environment]
        )
        removal.run { options[:yes] || confirm?(cli) }
        yield root if removal.changed? && !options[:skip_contract]
      end

      def self.confirm?(cli)
        raise Thor::Error, "Non-interactive removal requires --yes. Preview with --dry-run first." unless $stdin.tty?

        %w[y yes].include?(cli.ask("Remove the listed generated files and routes? [y/N]").strip.downcase)
      end

      def initialize(kind, name, root:, dry_run: false, force: false, remove_migrations: false,
                     output: $stdout, environment: nil)
        super(output: output, force: force)
        unless KINDS.include?(kind) && name && !name.empty?
          raise Thor::Error, "Usage: gemstack destroy model|controller|resource NAME"
        end

        @root = File.expand_path(root)
        @kind = kind
        @dry_run = dry_run
        @remove_migrations = remove_migrations
        @owners = owners_for(name)
        @manifest = GenerationManifest.new(@root)
        @environment = environment || ENV.fetch("GEMSTACK_ENV", "development")
        @migration_status = MigrationStatus.new(@root, environment: @environment)
        @migration_git_status = MigrationGitStatus.new(@root)
        @changed = false
      end

      def changed? = @changed

      def run
        plan!
        preview
        raise Thor::Error, "Nothing removed:\n  #{@conflicts.join("\n  ")}" unless @conflicts.empty?
        return self if @dry_run || (@files.empty? && @routes.empty?)

        if block_given? && !yield
          @output.puts("Cancelled; no files changed.")
          return self
        end

        verify_snapshot!
        apply
        self
      end

      private

      def owners_for(name)
        if @kind == "controller"
          controller = ControllerGenerator.new(name, [], root: @root)
          return ["controller:#{controller.file_name}"]
        end

        @spec = ResourceSpec.new(name)
        owners = ["model:#{@spec.file_name}"]
        owners += ["controller:#{@spec.plural}", "resource:#{@spec.file_name}"] if @kind == "resource"
        owners
      end

      def plan!
        @conflicts = []
        selected = @manifest.files.select { |_, entry| @owners.include?(entry["owner"]) }
        @migrations, @files = selected.partition { |path, _| path.start_with?("db/migrations/") }.map(&:to_h)
        @routes = @manifest.routes.select { |entry| @owners.include?(entry["owner"]) }
        @snapshots = {}
        plan_migrations
        @files.each { |path, entry| check_file(path, entry) }
        plan_routes
        check_dependencies if @spec && @files.key?("app/models/#{@spec.file_name}.rb")
      end

      def check_file(path, entry)
        if SHARED.include?(path) || !path.start_with?("app/", "test/", "frontend/", "db/migrations/")
          raise Thor::Error, "Refusing to remove shared or unsupported path: #{path}"
        end

        absolute = @manifest.absolute(path)
        raise Thor::Error, "Expected a generated file: #{path}" if File.exist?(absolute) && !File.file?(absolute)

        digest = File.file?(absolute) ? Digest::SHA256.file(absolute).hexdigest : nil
        @snapshots[path] = digest
        return unless digest && digest != entry["sha256"] && !@force

        @conflicts << "Modified file: #{path} (review it, then use --force to remove it explicitly)"
      end

      def plan_migrations
        return if @migrations.empty?

        @applied = @migration_status.applied
        @pending = @migrations.reject { |path, _| @applied.nil? || @applied.include?(File.basename(path)) }
        @migration_reasons = {}
        @auto_removed_migrations = {}

        @migrations.each do |path, entry|
          reason = migration_retention_reason(path)
          if reason
            @migration_reasons[path] = reason
          else
            @files[path] = entry
            @auto_removed_migrations[path] = entry unless @remove_migrations
          end
        end

        @migrations = @migrations.select { |path, _| @migration_reasons.key?(path) }
      end

      def migration_retention_reason(path)
        return "database state unknown" if @applied.nil?
        return "already applied" if @applied.include?(File.basename(path))
        return if @remove_migrations

        case @migration_git_status.committed(path)
        when true then "pending but committed to Git; use --remove-migrations to remove"
        when nil then "pending but Git state is unknown; use --remove-migrations to remove"
        end
      end

      def plan_routes
        path = @manifest.absolute("config/routes.rb")
        @route_content = File.file?(path) ? File.read(path, encoding: "UTF-8") : ""
        @route_after = @route_content.dup
        @routes.each do |entry|
          line = entry.fetch("line")
          unless @route_content.lines.count(line) == 1
            @conflicts << "Generated route was edited, removed or duplicated: #{line.strip.inspect}; restore it first"
            next
          end

          @route_after = @route_after.lines.reject { |candidate| candidate == line }.join
        end
        check_remaining_routes
      end

      def check_remaining_routes
        controllers = @files.keys.filter_map do |path|
          path.delete_prefix("app/controllers/").delete_suffix("_controller.rb") if
            path.start_with?("app/controllers/") && path.end_with?("_controller.rb")
        end
        tokens = Ripper.lex(@route_after).reject do |_, type, _, _|
          %i[on_sp on_ignored_nl on_nl on_comment].include?(type)
        end
        controllers.each do |controller|
          target = tokens.any? { |_, type, text, _| type == :on_tstring_content && text.start_with?("#{controller}#") }
          resource = resource_route?(tokens, controller)
          @conflicts << "Remaining route to #{controller}: config/routes.rb (remove it manually)" if target || resource
        end
      end

      def resource_route?(tokens, controller)
        tokens.each_cons(3).any? do |first, second, third|
          first[1] == :on_ident && %w[resources resource].include?(first[2]) && second[1] == :on_symbeg &&
            third[2] == controller.split("/").last
        end
      end

      # Conservative checks for direct Ruby constants and association symbols.
      # Dynamic references and application-specific frontend imports still need
      # review; destroy never rewrites application business logic.
      def check_dependencies
        Dir.glob(File.join(@root, "app/**/*.rb")).each do |absolute|
          relative = Pathname.new(absolute).relative_path_from(Pathname.new(@root)).to_s
          next if @files.key?(relative)

          @manifest.absolute(relative)
          tokens = Ripper.lex(File.read(absolute, encoding: "UTF-8"))
          constant = tokens.any? { |_, type, text, _| type == :on_const && text == @spec.class_name }
          association = tokens.each_cons(2).any? do |left, right|
            left[1] == :on_symbeg && %i[on_ident on_const].include?(right[1]) &&
              [@spec.file_name, @spec.plural].include?(right[2])
          end
          @conflicts << "Remaining Ruby reference to #{@spec.class_name}: #{relative}" if constant || association
        end
      end

      def preview
        @migrations.each_key do |path|
          status("keep", path, @migration_reasons.fetch(path))
        end
        unless @migrations.empty?
          @output.puts("To remove the table, review `gemstack db:status -e #{@environment}` and roll back with " \
                       "`gemstack db:rollback -e #{@environment}` " \
                       "if it is the latest migration, or add a migration that drops the table. " \
                       "These database operations can delete data; destroy never runs them.")
        end
        @files.each_key do |path|
          status(@snapshots[path] ? "remove" : "missing", path)
        end
        @routes.each { |entry| status("unroute", "config/routes.rb", entry["line"].strip) }
        if @files.empty? && @routes.empty?
          @output.puts("No tracked files to remove. Resources generated before ownership tracking need manual removal.")
        end
        @output.puts("Dry run; no files or API contracts changed.") if @dry_run
      end

      # Recheck after interactive confirmation, before the first mutation.
      def verify_snapshot!
        @manifest.verify!

        if @pending && !@pending.empty? && @migration_status.applied != @applied
          raise Thor::Error, "Migration state changed or became unavailable; run destroy again"
        end

        if @auto_removed_migrations&.any? { |path, _| @migration_git_status.committed(path) != false }
          raise Thor::Error, "Migration Git state changed; run destroy again"
        end

        @snapshots.each do |relative, original|
          path = @manifest.absolute(relative)
          current = File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil
          unless current == original
            raise Thor::Error,
                  "File changed during confirmation: #{relative}; run destroy again"
          end
        end

        path = @manifest.absolute("config/routes.rb")
        current = File.file?(path) ? File.read(path, encoding: "UTF-8") : ""
        return if current == @route_content

        raise Thor::Error, "Routes changed during confirmation; run destroy again"
      end

      def apply
        @files.each_key do |relative|
          path = @manifest.absolute(relative)
          File.delete(path) if File.file?(path)
        end
        File.write(@manifest.absolute("config/routes.rb"), @route_after) unless @routes.empty?
        @manifest.forget(@files.keys, @routes)
        @manifest.save
        @changed = true
        @output.puts("Removed tracked code. Database data was not changed.")
      end
    end
  end
end
