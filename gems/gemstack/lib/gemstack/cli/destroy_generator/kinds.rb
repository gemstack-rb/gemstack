# frozen_string_literal: true

module GemStack
  class CLI < Thor
    class DestroyGenerator < Generator
      # What each kind owns, and what `destroy job|policy|deploy` checks beyond
      # files and routes.
      module Kinds
        private

        def owners_for(name)
          case @kind
          when "controller" then return ["controller:#{ControllerGenerator.new(name, [], root: @root).file_name}"]
          when "job"
            @constant = JobGenerator.class_name_for(name)
            return ["job:#{Inflector.underscore(@constant)}"]
          when "policy"
            policy = PolicyGenerator.new(name, root: @root)
            @constant = policy.class_name
            return ["policy:#{policy.file_name}"]
          when "migration"
            file_name = Inflector.underscore(name.to_s)
            raise Thor::Error, "Invalid migration name #{name.inspect}" unless file_name.match?(/\A[a-z][a-z0-9_]*\z/)

            return ["migration:#{file_name}"]
          when "deploy" then return ["deploy:app"]
          end

          @spec = ResourceSpec.new(name)
          owners = ["model:#{@spec.file_name}"]
          owners += ["controller:#{@spec.plural}", "resource:#{@spec.file_name}"] if @kind == "resource"
          owners
        end

        # `gemstack generate deploy` adds exactly DeployGenerator::KAMAL_GEM; that
        # line is removed, an edited one is left for the user.
        def plan_gemfile
          path = @manifest.absolute("Gemfile")
          @gemfile_content = File.file?(path) ? File.read(path, encoding: "UTF-8") : ""
          lines = @gemfile_content.lines
          return unless lines.include?(DeployGenerator::KAMAL_GEM)

          @gemfile_after = "#{lines.reject { |line| line == DeployGenerator::KAMAL_GEM }.join.rstrip}\n"
        end

        # A job or policy that other code still names would break it at runtime.
        def check_constant_references
          Dir.glob(File.join(@root, "{app,config,lib}/**/*.rb")).each do |absolute|
            relative = Pathname.new(absolute).relative_path_from(Pathname.new(@root)).to_s
            next if @files.key?(relative)

            @manifest.absolute(relative)
            tokens = Ripper.lex(File.read(absolute, encoding: "UTF-8"))
            next unless tokens.any? { |_, type, text, _| type == :on_const && text == @constant.split("::").last }

            @conflicts << "Remaining Ruby reference to #{@constant}: #{relative}"
          end
        end

        def verify_gemfile!
          return if File.read(@manifest.absolute("Gemfile"), encoding: "UTF-8") == @gemfile_content

          raise Thor::Error, "Gemfile changed during confirmation; run destroy again"
        end
      end
    end
  end
end
