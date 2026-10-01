# frozen_string_literal: true

require "erb"
require "fileutils"

module GemStack
  class CLI < Thor
    # Shared machinery for generators: renders a template directory into a
    # destination. Files ending in .tt are ERB templates evaluated against the
    # generator; a leading "dot_" in a file name becomes "." (so dotfiles
    # survive gem packaging). Existing files are never overwritten silently.
    #
    # Applications can override any template by placing a file with the same
    # relative path in lib/templates/gemstack/<generator>/ (ARCHITECTURE §7).
    class Generator
      TEMPLATES = File.expand_path("../../../templates", __dir__)

      attr_reader :created

      def initialize(output: $stdout, force: false)
        @output = output
        @force = force
        @created = []
      end

      def template_root(name) = File.join(TEMPLATES, name)

      # Ruby core/stdlib names an app class must not reuse (a top-level class
      # named Digest or Set would collide with Ruby's own). Constants already
      # defined in this process (stdlib and gems loaded by the CLI) are
      # checked too; the app's own code isn't loaded here, so those are always
      # foreign.
      RESERVED = %w[
        Array BasicObject Benchmark Binding Class Comparable Data Date DateTime Digest Dir Encoding Enumerable
        Enumerator Errno Exception FalseClass Fiber File FileTest FileUtils Float GC Hash IO Integer JSON Kernel
        Logger Marshal MatchData Math Method Module Monitor Mutex NilClass Numeric Object ObjectSpace Observable
        OpenStruct Pathname Proc Process Queue Random Range Rational Regexp Ripper Set Signal Socket String
        StringIO Struct Symbol Thread Time Timeout TracePoint TrueClass URI Warning Zlib Rack Sequel Thor Puma
        GemStack
      ].freeze

      def self.check_constant!(name, suggestion: nil)
        top = name.to_s.split("::").first
        return unless RESERVED.include?(top) || Object.const_defined?(top, false)

        hint = suggestion ? " — try #{suggestion}" : ""
        raise Thor::Error, "#{name} would clash with Ruby's (or a loaded gem's) #{top} constant#{hint}"
      end

      # A migration version not used yet in db/migrations: generating several
      # migrations within one second must not give them the same version.
      def self.migration_timestamp(root, time = Time.now.utc)
        loop do
          stamp = time.strftime("%Y%m%d%H%M%S")
          return stamp if Dir.glob(File.join(root.to_s, "db/migrations/#{stamp}_*.rb")).empty?

          time += 1
        end
      end

      # Every template file for a generator, with app overrides applied.
      # The app's base classes (written by `gemstack new` since 0.2.1). Apps
      # created earlier get the ones a generator's code inherits from.
      BASE_CLASSES = {
        model: "app/models/application_model.rb", serializer: "app/serializers/application_serializer.rb",
        job: "app/jobs/application_job.rb", mailer: "app/mailers/application_mailer.rb"
      }.freeze

      # Which GemStack modules an app uses. Since 0.3.0 the core modules are
      # part of the gemstack gem and switched on with `require "gemstack/db"`
      # (etc.) in config/app.rb; apps from before list gemstack-db in the
      # Gemfile. Auth and realtime are gems of their own either way.
      MODULE_GEMS = %w[auth realtime].freeze

      def self.uses?(root, name)
        name = name.to_s
        gemfile = read_file(root, "Gemfile")
        return true if gemfile.match?(/^\s*gem "gemstack-#{name}"/)
        return false if MODULE_GEMS.include?(name)

        read_file(root, "config/app.rb").match?(%r{^\s*require "gemstack/#{name}"})
      end

      def self.read_file(root, rel) = File.file?(File.join(root, rel)) ? File.read(File.join(root, rel)) : ""

      # Whether the app has jobs or mailers of its own (base classes don't count).
      def self.background_work?(root)
        %w[app/jobs/*.rb app/mailers/*.rb].any? do |glob|
          Dir.glob(File.join(root, glob)).any? { |file| !File.basename(file).start_with?("application_") }
        end
      end

      def ensure_base_classes(root, *kinds)
        kinds.each do |kind|
          rel = BASE_CLASSES.fetch(kind)
          target = File.join(root, rel)
          write(target, File.read(File.join(template_root("app"), rel))) unless File.exist?(target)
        end
      end

      def template_files(name, override_root: nil)
        files = relative_files(template_root(name)).to_h { |rel| [rel, File.join(template_root(name), rel)] }
        if override_root
          custom = File.join(override_root, "lib/templates/gemstack", name)
          relative_files(custom).each { |rel| files[rel] = File.join(custom, rel) } if File.directory?(custom)
        end
        files
      end

      def render_directory(name, destination, override_root: nil, skip: nil)
        template_files(name, override_root: override_root).sort.each do |rel, source|
          next if skip&.call(rel)

          target = File.join(destination, output_path(rel))
          content = File.binread(source)
          content = render(content, source) if source.end_with?(".tt")
          write(target, content, mode: File.stat(source).mode)
        end
      end

      def render(content, source = "(template)")
        erb = ERB.new(content, trim_mode: "-")
        erb.filename = source
        erb.result(binding)
      end

      def write(path, content, mode: nil)
        if File.exist?(path) && !@force
          if File.binread(path) == content
            status("identical", path)
          else
            status("skip", path, "exists — not overwritten")
          end
          return false
        end
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, content)
        File.chmod(mode & 0o777, path) if mode
        @created << path
        status("create", path)
        true
      end

      def write_tracked(path, content, owner:)
        relative = Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(File.expand_path(@root))).to_s
        @manifest.absolute(relative)
        existed = File.exist?(path)
        return unless write(path, content)

        @manifest.record_file(path, owner: owner, existed: existed)
      end

      def status(label, path, note = nil)
        shown = path.delete_prefix("#{Dir.pwd}/")
        @output.puts("  #{label.rjust(9)}  #{shown}#{"  (#{note})" if note}")
      end

      private

      def relative_files(root)
        Dir.glob("**/*", File::FNM_DOTMATCH, base: root)
           .reject { |rel| File.directory?(File.join(root, rel)) || File.basename(rel) == ".DS_Store" }
      end

      def output_path(rel)
        rel.delete_suffix(".tt").split("/").map { |part| part.sub(/\Adot_/, ".") }.join("/")
      end
    end
  end
end
