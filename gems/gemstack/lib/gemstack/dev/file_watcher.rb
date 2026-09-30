# frozen_string_literal: true

require "digest"

module GemStack
  module Dev
    # Detects changes (edits, additions, deletions) in a set of glob patterns.
    # Polling keeps it dependency-free and reliable across editors, containers
    # and network filesystems; it is only used in development.
    #
    # Modification times are the cheap first check; a file whose mtime changed
    # only counts as changed if its content digest changed too. Tools that
    # rewrite files with identical content — Bundler 4 rewrites Gemfile.lock on
    # every `bundle exec` — therefore don't trigger reloads or restarts.
    class FileWatcher
      Entry = Struct.new(:mtime, :bytes, :digest)

      def initialize(patterns, root: Dir.pwd, exclude: [])
        @patterns = Array(patterns)
        @exclude = Array(exclude)
        @root = root.to_s
        @entries = scan({})
      end

      # True once per change: the new state becomes the baseline.
      def changed?
        current = scan(@entries)
        changed = current.keys != @entries.keys ||
                  current.any? { |path, entry| entry.digest != @entries[path].digest }
        @entries = current
        changed
      end

      def files
        found = Dir.glob(@patterns, base: @root)
        found.reject! { |file| @exclude.any? { |pattern| File.fnmatch?(pattern, file, File::FNM_PATHNAME) } }
        found.sort
      end

      private

      # Reuses the previous digest when mtime and size are unchanged.
      def scan(previous)
        files.each_with_object({}) do |file, entries|
          path = File.join(@root, file)
          stat = File.stat(path)
          next if stat.directory?

          old = previous[file]
          same = old && old.mtime == stat.mtime && old.bytes == stat.size
          entries[file] = Entry.new(stat.mtime, stat.size, same ? old.digest : Digest::SHA256.file(path).hexdigest)
        rescue Errno::ENOENT
          next
        end
      end
    end
  end
end
