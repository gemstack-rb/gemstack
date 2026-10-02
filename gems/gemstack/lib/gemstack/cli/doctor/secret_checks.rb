# frozen_string_literal: true

module GemStack
  class CLI < Thor
    class Doctor
      # Secrets must never be committed: no secret files tracked by git, and
      # .kamal/secrets (which is committed) may only reference secrets
      # ($NAME, $(kamal secrets fetch …)); a value written in place is a leak.
      module SecretChecks
        def check_git_secrets
          return unless File.directory?(path(".git"))

          out, status = @run.call("git", "-C", @root, "ls-files", "--", ".env", ".env.*", "*.pem", "*.key",
                                  "tmp/*_secret")
          return unless status.success?

          tracked = out.lines.map(&:strip).reject { |file| file.empty? || file.end_with?(".example") }
          if tracked.empty?
            pass("no secret files tracked by git")
          else
            problem("secret files tracked by git: #{tracked.join(", ")}",
                    "remove them from git (git rm --cached …), rotate every secret they contain, and ask whoever " \
                    "manages your infrastructure to check where the repository was shared")
          end
        end

        def check_kamal_secrets
          content = read(".kamal/secrets")
          return unless content

          literal = content.lines.filter_map do |line|
            name, value = line.strip.split("=", 2)
            next if name.nil? || name.start_with?("#") || value.nil?

            value = value.strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
            name unless value.empty? || value.include?("$")
          end
          if literal.empty?
            pass(".kamal/secrets only references secrets")
          else
            problem(".kamal/secrets contains secret values: #{literal.join(", ")}",
                    "replace each with a reference (NAME=$NAME, or $(kamal secrets fetch …)), rotate those " \
                    "secrets, and ask whoever manages your infrastructure to check where the repository was shared")
          end
        end
      end
    end
  end
end
