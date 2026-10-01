# frozen_string_literal: true

require "open3"

module GemStack
  class CLI < Thor
    # Unknown or incomplete history must never authorize automatic deletion.
    class MigrationGitStatus
      def initialize(root)
        @root = root
      end

      def committed(path)
        return unless git("rev-parse", "--is-inside-work-tree") == "true"

        history = git("log", "--all", "-1", "--format=%H", "--", path)
        return if history.nil?
        return true unless history.empty?
        return unless git("rev-parse", "--is-shallow-repository") == "false"

        false
      end

      private

      def git(*)
        output, _, status = Open3.capture3("git", "--literal-pathspecs", "-C", @root, *)
        output.strip if status.success?
      rescue SystemCallError
        nil
      end
    end
  end
end
