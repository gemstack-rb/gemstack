# frozen_string_literal: true

require "digest"

module GemStack
  class CLI < Thor
    # The deploy half of `gemstack update --templates`: the files
    # `gemstack generate deploy` wrote (Dockerfile, config/deploy.yml,
    # .kamal/secrets, bin/…). .gemstack/generators.json records each one's
    # content as generated: a file that still matches was never edited and is
    # updated; for one you edited, the release whose render matches is the base
    # the merge starts from. Files a release adds (bin/deploy) are created.
    module DeployFiles
      DEPLOY_OWNER = "deploy:app"
      # What DeployGenerator reads to decide what to write (frontend? database? jobs? mail?).
      DEPLOY_INPUTS = %w[Gemfile Gemfile.lock config/app.rb config/database.yml .ruby-version .tool-versions
                         frontend/package.json frontend/next.config.ts].freeze

      private

      def update_deploy_files
        @manifest = GenerationManifest.new(@root)
        tracked = @manifest.files.select { |_, entry| entry["owner"] == DEPLOY_OWNER }
        return unless tracked.any? || File.file?(File.join(@root, "config/deploy.yml"))

        Dir.mktmpdir("gemstack-deploy-templates") do |cache|
          @deploy_cache = cache
          tree = render_deploy(Generator::TEMPLATES)
          @output.puts("  Deploy files: couldn't render this version's deploy templates; skipped") unless tree
          tree&.each { |path, file| apply_deploy(path, file, tracked[path]) }
        end
        @manifest.save unless @dry_run
      end

      def apply_deploy(path, file, entry)
        mine_path = File.join(@root, path)
        mine = File.binread(mine_path) if File.file?(mine_path)
        return if mine == file.content
        return (entry ? @result.removed << path : record_deploy(path, file) { create(path, file) }) if mine.nil?
        if entry && Digest::SHA256.hexdigest(mine) == entry["sha256"] # never edited
          return record_deploy(path, file) { update(path, file, :updated) }
        end

        base = deploy_base(path, entry)
        return if base == file.content # this release didn't change it: your edits are yours

        bases = base ? [base] : deploy_bases(path)
        reason = "is new in this version, and you have your own" if entry.nil? && bases.empty?
        record_deploy(path, file) { conflict(path, file, mine, bases, **{ reason: reason }.compact) }
      end

      # Runs the write, then records what the file now derives from: the new
      # template, unless you kept yours (skip / FILE.new).
      def record_deploy(path, file)
        yield
        written = (@result.created + @result.updated + @result.merged + @result.marked).include?(path)
        @manifest.record_content(path, owner: DEPLOY_OWNER, content: file.content) if written && !@dry_run
      end

      # The template this file was generated from: the release render whose
      # content matches the recorded checksum.
      def deploy_base(path, entry)
        return nil unless entry

        deploy_releases.each do |source|
          content = deploy_render(source)&.dig(path)&.content
          return content if content && Digest::SHA256.hexdigest(content) == entry["sha256"]
        end
        nil
      end

      # Without a recorded base: every earlier release's version of the file
      # (this release's isn't a base — merging with it would just keep yours).
      def deploy_bases(path)
        deploy_releases.drop(1).filter_map { |source| deploy_render(source)&.dig(path)&.content }.uniq
      end

      # This release (what a merged file was recorded against), the recorded
      # version, then every earlier release, newest first.
      def deploy_releases
        @deploy_releases ||= [Generator::TEMPLATES] +
                             if @old_templates then Array(@old_templates)
                             else ([@from] + TemplateSource.releases_before(GemStack::VERSION).reverse).compact.uniq
                             end
      end

      def deploy_render(source)
        (@deploy_renders ||= {}).fetch(source) do
          templates = File.directory?(source.to_s) ? source : TemplateSource.locate(source, cache: @deploy_cache)
          @deploy_renders[source] = templates && render_deploy(templates)
        end
      end

      # `gemstack generate deploy` for this app (its database, frontend, jobs,
      # pinned versions and any lib/templates/gemstack/deploy overrides), in a
      # scratch copy of the files it reads.
      def render_deploy(templates)
        Dir.mktmpdir("gemstack-render-deploy") do |dir|
          sandbox = File.join(dir, File.basename(@root))
          copy_deploy_inputs(sandbox)
          generator = DeployGenerator.new(root: sandbox, output: StringIO.new, templates: templates)
          generator.run
          generator.created.filter_map do |full|
            rel = full.delete_prefix("#{sandbox}/")
            [rel, TemplateUpdate::AppFile.new(File.binread(full), File.stat(full).mode)] unless rel == "vendor/.keep"
          end.to_h
        end
      rescue StandardError
        nil # a release whose deploy templates this version can't render: compare without it
      end

      def copy_deploy_inputs(sandbox)
        globs = DEPLOY_INPUTS + %w[app/jobs/*.rb app/mailers/*.rb lib/templates/gemstack/deploy/**/*]
        globs.flat_map { |glob| Dir.glob(glob, File::FNM_DOTMATCH, base: @root) }.each do |rel|
          source = File.join(@root, rel)
          next unless File.file?(source)

          FileUtils.mkdir_p(File.dirname(File.join(sandbox, rel)))
          FileUtils.cp(source, File.join(sandbox, rel))
        end
        File.write(File.join(sandbox, "Gemfile"), "") unless File.file?(File.join(sandbox, "Gemfile"))
      end
    end
  end
end
