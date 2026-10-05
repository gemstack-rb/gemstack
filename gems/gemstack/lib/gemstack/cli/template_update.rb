# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "open3"
require "rubygems/package"
require "stringio"
require "tempfile"
require "tmpdir"

module GemStack
  class CLI < Thor
    # Finds the templates/ directory of a GemStack version: this one, an
    # installed gem, or the gem downloaded from rubygems.org.
    module TemplateSource
      module_function

      # Releases since templates took their current layout (0.3.0).
      FIRST = Gem::Version.new("0.3.0")

      def locate(version, cache: Dir.mktmpdir("gemstack-templates"))
        return Generator::TEMPLATES if version == GemStack::VERSION

        installed(version) || download(version, cache)
      end

      # Every release before VERSION (rubygems.org's list, or the installed ones offline).
      def releases_before(version)
        limit = Gem::Version.new(version)
        names = published_versions || installed_versions
        names.map { |name| Gem::Version.new(name) }
             .select { |v| !v.prerelease? && v >= FIRST && v < limit }.sort.map(&:to_s)
      end

      def published_versions
        response = Net::HTTP.get_response(URI("https://rubygems.org/api/v1/versions/gemstack.json"))
        JSON.parse(response.body).map { |release| release.fetch("number") } if response.is_a?(Net::HTTPSuccess)
      rescue StandardError
        nil
      end

      def installed_versions
        gem_dirs.flat_map { |dir| Dir[File.join(dir, "gems", "gemstack-*", "templates")] }
                .filter_map { |path| path[%r{gemstack-(\d+\.\d+\.\d+)/templates\z}, 1] }.uniq
      end

      def gem_dirs = (Gem.path + [(Bundler.bundle_path.to_s if defined?(Bundler))]).compact.uniq

      def installed(version)
        gem_dirs.map { |dir| File.join(dir, "gems", "gemstack-#{version}", "templates") }
                .find { |path| File.directory?(path) }
      end

      def download(version, cache)
        cache = File.join(cache, version)
        FileUtils.mkdir_p(cache)
        response = Net::HTTP.get_response(URI("https://rubygems.org/downloads/gemstack-#{version}.gem"))
        return unless response.is_a?(Net::HTTPSuccess)

        gem = File.join(cache, "gemstack-#{version}.gem")
        File.binwrite(gem, response.body)
        Gem::Package.new(gem).extract_files(cache, "templates/**/*")
        templates = File.join(cache, "templates")
        templates if File.directory?(templates)
      rescue StandardError
        nil
      end
    end

    # The template half of `gemstack update`: brings the files `gemstack new`
    # wrote into line with this GemStack version. Each file is compared three
    # ways — the app's copy, the old version's template and this version's,
    # both rendered for this app — so only files a release changed are touched:
    #
    #   template unchanged            skipped (your edits are yours)
    #   new in this version           created
    #   you never edited the file     updated
    #   you edited it                 you choose: overwrite, skip, diff, or save as FILE.new
    #
    # Apps record the templates they're on in .gemstack/version. Older apps don't,
    # so each file is compared with every earlier release's template: matching
    # one means you never edited it (it's just out of date). Without any old
    # templates (offline), files that differ are offered, never updated.
    class TemplateUpdate
      VERSION_FILE = ".gemstack/version"
      # Managed elsewhere: the Gemfile by `gemstack update`/Bundler.
      MANAGED = %w[Gemfile .gemstack/version].freeze

      # created/updated/saved (as FILE.new) are done; conflicts were left for you;
      # removed are files you deleted, which stay deleted.
      Result = Struct.new(:created, :updated, :saved, :conflicts, :removed, keyword_init: true)

      def self.recorded_version(root)
        path = File.join(root, VERSION_FILE)
        File.read(path).strip if File.file?(path)
      end

      def initialize(root:, from: nil, output: $stdout, dry_run: false, interactive: $stdin.tty?, prompt: nil,
                     old_templates: nil)
        @root = root
        @from = from || self.class.recorded_version(root)
        @output = output
        @dry_run = dry_run
        @interactive = interactive && !dry_run
        @prompt = prompt || lambda { |question|
          @output.print("  #{question} ")
          $stdin.gets.to_s.strip.downcase
        }
        @old_templates = old_templates
        @result = Result.new(created: [], updated: [], saved: [], conflicts: [], removed: [])
      end

      def run
        new_tree = render(Generator::TEMPLATES, version: GemStack::VERSION)
        old_trees = old_trees_for_comparison
        new_tree.each { |path, file| apply(path, file, old_trees.map { |tree| tree[path]&.content }) }
        report
        record_version unless @dry_run || @result.conflicts.any?
        @result
      end

      private

      AppFile = Struct.new(:content, :mode)

      # The renders to compare with: the recorded/given version's, or every
      # earlier release's when the app doesn't say which it came from.
      def old_trees_for_comparison
        trees = if @old_templates
                  Array(@old_templates).map { |templates| render(templates, version: GemStack::VERSION) }
                else
                  release_trees(@from ? [@from] : TemplateSource.releases_before(GemStack::VERSION))
                end
        describe(trees)
        trees
      end

      def release_trees(versions)
        @versions = versions
        Dir.mktmpdir("gemstack-templates") do |cache|
          versions.filter_map do |version|
            source = TemplateSource.locate(version, cache: cache)
            render(source, version: version) if source
          rescue Thor::Error
            nil # an old template this version can't render: compare without it
          end
        end
      end

      def describe(trees)
        if trees.empty?
          @output.puts("Templates: earlier GemStack templates aren't available, so files that differ are " \
                       "offered, never updated automatically")
        elsif @from
          @output.puts("Templates: comparing GemStack #{@from}'s with #{GemStack::VERSION}'s")
        else
          range = @versions&.any? ? " (#{@versions.first} to #{@versions.last})" : ""
          @output.puts("Templates: the app doesn't record its templates version, so files are compared with " \
                       "every earlier release#{range}")
        end
      end

      # Renders `gemstack new` for this app (its name, database, frontend, pinned
      # Ruby and Node.js) from a release's templates, as that release wrote them.
      def render(templates, version:)
        Dir.mktmpdir("gemstack-render") do |dir|
          name = File.basename(@root).downcase.gsub(/[^a-z0-9_-]/, "-").sub(/\A[^a-z]+/, "")
          destination = File.join(dir, name.empty? ? "app" : name)
          options = app_options.merge(templates: templates, version: version)
          AppGenerator.new(destination, options, output: StringIO.new).run
          Dir.glob("**/*", File::FNM_DOTMATCH, base: destination).sort.filter_map do |rel|
            full = File.join(destination, rel)
            next unless File.file?(full) && !MANAGED.include?(rel)

            [rel, AppFile.new(File.binread(full), File.stat(full).mode)]
          end.to_h
        end
      rescue StandardError => e
        raise Thor::Error, "Couldn't render the app templates (#{e.class}: #{e.message.lines.first&.strip})"
      end

      def app_options
        database_yml = File.join(@root, "config/database.yml")
        adapter = File.file?(database_yml) && File.read(database_yml)[/^\s+adapter:\s*(\w+)/, 1]
        {
          skip_install: true, skip_git: true,
          skip_frontend: !File.file?(File.join(@root, "frontend/package.json")),
          skip_database: !adapter, database: adapter || nil,
          ruby_version: pinned(".ruby-version")&.delete_prefix("ruby-"),
          node_version: pinned(".nvmrc") || pinned(".node-version")
        }.compact
      end

      def pinned(file)
        path = File.join(@root, file)
        File.read(path).strip.delete_prefix("v").then { |value| value unless value.empty? } if File.file?(path)
      end

      # olds: this file's content in each compared release's render (nil where absent).
      def apply(path, file, olds)
        mine_path = File.join(@root, path)
        mine = File.binread(mine_path) if File.file?(mine_path)
        return if mine == file.content
        return if olds.any? && olds.all?(file.content) # no release changed it: your edits are yours
        # Missing: new to your app if some compared release didn't have it either;
        # deleted by you if every one did (then it stays deleted).
        return create(path, file) if mine.nil? && (olds.empty? || olds.include?(nil))
        return @result.removed << path if mine.nil?
        return update(path, file, :updated) if olds.include?(mine) # an unedited, older copy

        conflict(path, file, mine)
      end

      def create(path, file)
        write(path, file)
        @result.created << path
        status("create", path)
      end

      def update(path, file, kind)
        write(path, file)
        @result.public_send(kind) << path
        status("update", path)
      end

      def conflict(path, file, mine)
        return record_conflict(path) unless @interactive

        loop do
          case @prompt.call("#{path} changed in this version and you edited it — [o]verwrite, [s]kip, " \
                            "[d]iff, save as [n]ew file?")
          when "o" then return update(path, file, :updated)
          when "n" then return save_new(path, file)
          when "d" then @output.puts(diff(mine, file.content, path))
          else return record_conflict(path)
          end
        end
      end

      def save_new(path, file)
        write("#{path}.new", file)
        @result.saved << path
        status("create", "#{path}.new")
      end

      def record_conflict(path)
        @result.conflicts << path
        status("conflict", path)
      end

      def write(path, file)
        return if @dry_run

        target = File.join(@root, path)
        FileUtils.mkdir_p(File.dirname(target))
        File.binwrite(target, file.content)
        File.chmod(file.mode & 0o777, target)
      end

      def diff(mine, theirs, path)
        Tempfile.create("mine") do |a|
          Tempfile.create("new") do |b|
            a.write(mine)
            b.write(theirs)
            [a, b].each(&:flush)
            labels = ["--label", "#{path} (yours)", "--label", "#{path} (new)"]
            out, = Open3.capture2("diff", "-u", *labels, a.path, b.path)
            out
          end
        end
      rescue SystemCallError
        "(diff isn't available on this system)"
      end

      def report
        done = { "created" => @result.created, "updated" => @result.updated, "saved as .new" => @result.saved,
                 "left for you" => @result.conflicts }.reject { |_, paths| paths.empty? }
        if done.empty?
          @output.puts("  nothing to update")
        else
          @output.puts("  #{done.map { |label, paths| "#{paths.size} #{label}" }.join(", ")}" \
                       "#{" — dry run, nothing written" if @dry_run}")
        end
        return if @result.conflicts.empty?

        @output.puts("  Review those in a terminal: gemstack update --templates#{" --from #{@from}" if @from}")
      end

      def record_version
        target = File.join(@root, VERSION_FILE)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, "#{GemStack::VERSION}\n")
      end

      def status(label, path) = @output.puts("  #{label.rjust(9)}  #{path}")
    end
  end
end
