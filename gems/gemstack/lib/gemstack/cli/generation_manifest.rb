# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "tempfile"

module GemStack
  class CLI < Thor
    # Ownership, not filename guesses, determines what destroy may remove.
    # Commit this file with the generated code so ownership survives a checkout.
    class GenerationManifest
      PATH = ".gemstack/generators.json"
      VERSION = 1

      attr_reader :files, :routes

      def initialize(root)
        @root = File.expand_path(root)
        @path = absolute(PATH)
        @fingerprint = fingerprint
        data = File.file?(@path) ? JSON.parse(File.read(@path, encoding: "UTF-8")) : empty
        validate!(data)
        @files = data.fetch("files")
        @routes = data.fetch("routes")
        @dirty = false
      rescue JSON::ParserError => e
        raise Thor::Error, "Invalid #{PATH}: #{e.message}"
      end

      # Reject traversal and symlinks, including symlinked parent directories.
      # Never follow a manifest entry outside this application, even with --force.
      def absolute(relative)
        parts = relative.to_s.split("/", -1)
        if parts.empty? || parts.intersect?(["", ".", ".."]) || relative.include?("\0")
          raise Thor::Error, "Unsafe generated path: #{relative.inspect}"
        end

        parts.reduce(@root) do |parent, part|
          path = File.join(parent, part)
          raise Thor::Error, "Refusing symlink: #{relative}" if File.symlink?(path)

          path
        end
      end

      def record_file(path, owner:, existed:)
        relative = Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@root)).to_s
        absolute(relative)
        previous = files[relative]
        return if existed && (!previous || previous["owner"] != owner)

        files[relative] = { "owner" => owner, "sha256" => Digest::SHA256.file(path).hexdigest }
        @dirty = true
      end

      def record_route(line, owner:)
        entry = { "owner" => owner, "line" => line }
        return if routes.include?(entry)

        routes << entry
        @dirty = true
      end

      def forget(paths, removed_routes)
        paths.each { |path| files.delete(path) }
        @routes -= removed_routes
        @dirty = true
      end

      def save
        return unless @dirty

        verify!
        FileUtils.mkdir_p(File.dirname(@path))
        data = { "version" => VERSION, "files" => files.sort.to_h, "routes" => routes }
        Tempfile.create(["generators", ".json"], File.dirname(@path)) do |file|
          file.write("#{JSON.pretty_generate(data)}\n")
          file.close
          File.rename(file.path, @path)
        end
        @dirty = false
        @fingerprint = fingerprint
      end

      def verify!
        absolute(PATH)
        return if fingerprint == @fingerprint

        raise Thor::Error, "#{PATH} changed while the command was running; retry the command"
      end

      private

      def empty = { "version" => VERSION, "files" => {}, "routes" => [] }

      def fingerprint = File.file?(@path) ? Digest::SHA256.file(@path).hexdigest : nil

      def validate!(data)
        valid = data.is_a?(Hash) && data["version"] == VERSION && data["files"].is_a?(Hash) &&
                data["routes"].is_a?(Array)
        valid &&= data["files"].all? { |path, entry| file_entry?(path, entry) }
        valid &&= data["routes"].all? { |entry| route_entry?(entry) }
        raise Thor::Error, "Invalid or unsupported #{PATH}; no files changed" unless valid
      end

      def file_entry?(path, entry)
        path.is_a?(String) && entry.is_a?(Hash) && owner?(entry["owner"]) &&
          entry["sha256"].is_a?(String) && entry["sha256"].match?(/\A[0-9a-f]{64}\z/)
      end

      def route_entry?(entry)
        entry.is_a?(Hash) && owner?(entry["owner"]) && entry["line"].is_a?(String) &&
          entry["line"].lines.size == 1 && entry["line"].end_with?("\n")
      end

      def owner?(owner)
        owner.is_a?(String) && owner.match?(%r{\A(?:model|controller|resource):[a-z][a-z0-9_]*(?:/[a-z][a-z0-9_]*)*\z})
      end
    end
  end
end
