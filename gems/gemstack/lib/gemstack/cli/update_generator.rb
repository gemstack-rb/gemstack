# frozen_string_literal: true

require "bundler"

module GemStack
  class CLI < Thor
    # Shared machinery for generators: renders a template directory into a
    # destination. Files ending in .tt are ERB templates evaluated against the
    # generator; a leading "dot_" in a file name becomes "." (so dotfiles
    # survive gem packaging). Existing files are never overwritten silently.
    #
    # Applications can override any template by placing a file with the same
    # relative path in lib/templates/gemstack/<generator>/ (ARCHITECTURE §7).
    class UpdateGenerator < Generator
      def run
        root = Project.root!
        @output.puts "Checking current GemStack version..."

        # Read Gemfile
        gemfile_path = File.join(root, "Gemfile")
        unless File.exist?(gemfile_path)
          @output.puts "Error: Gemfile not found in #{root}"
          return false
        end

        gemfile_content = File.read(gemfile_path)

        # Check how gemstack is referenced
        if gemfile_content.match?(/^\s*gem "gemstack"/)
          # Check if it's within a path block
          path_match = gemfile_content.match?(/path\s+"[^"]*"\s+do\s*$/m)
          gemstone_in_path = gemfile_content.match?(/path\s+"[^"]*"\s+do\s*.*^\s*gem "gemstack"/m)
          if path_match && gemstone_in_path
            # Path dependency (from local checkout)
            @output.puts "Your Gemfile uses a path dependency to GemStack:"
            @output.puts gemfile_content[/path\s+"[^"]*"\s+do\s*/m].strip
            @output.puts "To update GemStack, you need to update your local GemStack checkout."
            @output.puts "Run: cd /path/to/your/gemstack/checkout && git pull"
            true
          else
            # Versioned dependency
            update_versioned_dependency(gemfile_path, gemfile_content)
          end
        else
          @output.puts "Error: Could not find gemstack dependency in Gemfile"
          false
        end
      end

      private

      def update_versioned_dependency(gemfile_path, gemfile_content)
        current_constraint = determine_current_version_constraint(gemfile_content)
        @output.puts "Current GemStack version constraint: ~> #{current_constraint}"

        # Update to latest version
        new_constraint = GemStack::VERSION
        new_content = gemfile_content.sub(
          /(^\s*gem "gemstack",\s*"~>\s*)[^"]+(")/,
          "\\1#{new_constraint}\\2"
        )

        if new_content == gemfile_content
          @output.puts "Error: Failed to update Gemfile"
          return false
        end

        # Write updated Gemfile
        File.write(gemfile_path, new_content)
        @output.puts "Updated Gemfile to use GemStack ~> #{new_constraint}"

        # Run bundle update
        run_bundle_update
      end

      def determine_current_version_constraint(gemfile_content)
        if gemfile_content.match?(/^\s*gem "gemstack",\s*"~>\s*([^"]+)"/)
          Regexp.last_match(1)
        else
          # Try to find any version constraint for gemstack
          if gemfile_content.match?(/^\s*gem "gemstack",\s*"([^"]*)"/)
            found_constraint = Regexp.last_match(1)
            if found_constraint.empty?
              @output.puts "Warning: Empty version constraint, assuming ~> #{GemStack::VERSION}"
              GemStack::VERSION
            else
              found_constraint
            end
          else
            @output.puts "Warning: Could not determine current version constraint, assuming ~> #{GemStack::VERSION}"
            GemStack::VERSION
          end
        end
      end

      def run_bundle_update
        @output.puts "Running bundle update gemstack..."
        if Bundler.with_unbundled_env { system("bundle", "update", "gemstack") }
          @output.puts "Successfully updated GemStack to version #{GemStack::VERSION}"
          @output.puts ""
          @output.puts "Next steps:"
          @output.puts "  1. Review any release notes for breaking changes"
          @output.puts "  2. Run your test suite to ensure compatibility"
          @output.puts "  3. If you have migrations, run: gemstack db:migrate"
          true
        else
          @output.puts "Error: bundle update gemstack failed"
          @output.puts "You may need to run it manually or resolve conflicts"
          false
        end
      end
    end
  end
end
