# frozen_string_literal: true

module GemStack
  class CLI < Thor
    # `gemstack generate controller Products index show create`
    #
    # Creates the controller, a test per action and the matching routes.
    # Conventional action names map to REST routes; any other action becomes
    # GET /<resource>/<action>.
    class ControllerGenerator < Generator
      REST = {
        "index" => ["get", ""], "show" => ["get", "/:id"], "create" => ["post", ""],
        "update" => ["patch", "/:id"], "destroy" => ["delete", "/:id"]
      }.freeze
      ROUTES_BLOCK = /^GemStack\.routes do[ \t]*\n/

      attr_reader :file_name, :class_name, :actions, :url_path

      def initialize(name, actions, root:, output: $stdout, force: false)
        super(output: output, force: force)
        @root = root
        @file_name = Inflector.underscore(name.to_s.delete_suffix("Controller")) # "admin/products"
        @class_name = "#{Inflector.camelize(@file_name)}Controller"              # "Admin::ProductsController"
        @actions = (actions.empty? ? ["index"] : actions).map { |a| Inflector.underscore(a) }.uniq
        @url_path = "/#{@file_name.split("/").map { |part| Inflector.dasherize(part) }.join("/")}"
        validate!
      end

      def run
        @manifest = GenerationManifest.new(@root)
        template_files("controller", override_root: @root).each do |rel, source|
          target = File.join(@root, rel.delete_suffix(".tt").gsub("%file_name%", file_name))
          write_tracked(target, render(File.read(source, encoding: "UTF-8"), source), owner: "controller:#{file_name}")
        end
        add_routes
        self
      ensure
        @manifest&.save
      end

      def route_for(action)
        verb, suffix = REST.fetch(action) { ["get", "/#{Inflector.dasherize(action)}"] }
        [verb, url_path + suffix]
      end

      # Example path for tests: :id becomes 1.
      def request_path(action) = "/api#{route_for(action)[1].sub(":id", "1")}"

      def route_line(action)
        verb, path = route_for(action)
        %(#{verb} "#{path}", to: "#{file_name}##{action}")
      end

      private

      def validate!
        invalid = actions.grep_v(/\A[a-z_][a-z0-9_]*\z/)
        raise Thor::Error, "Invalid action name(s): #{invalid.join(", ")}" unless invalid.empty?
        raise Thor::Error, "Invalid controller name" unless file_name.match?(%r{\A[a-z][a-z0-9_/]*\z})
      end

      def add_routes
        path = File.join(@root, "config/routes.rb")
        return status("skip", path, "not found — add routes manually") unless File.file?(path)

        @manifest.absolute("config/routes.rb")
        content = File.read(path, encoding: "UTF-8")
        lines = actions.map { |action| route_line(action) }.reject { |line| content.include?(line) }
        return status("identical", path) if lines.empty?
        return status("skip", path, "no `GemStack.routes do` block found") unless content.match?(ROUTES_BLOCK)

        File.write(path, content.sub(ROUTES_BLOCK) { |open| open + lines.map { |l| "  #{l}\n" }.join })
        lines.each { |line| @manifest.record_route("  #{line}\n", owner: "controller:#{file_name}") }
        status("route", path, lines.join("; "))
      end
    end
  end
end
