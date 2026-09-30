# frozen_string_literal: true

module GemStack
  module HTTP
    # Routes requests to controllers or Rack apps.
    #
    #   router = Router.new(prefix: "/api")
    #   router.draw do
    #     get "/status", to: "status#show"
    #     resources :products do
    #       member { post "/publish", action: :publish }
    #       resources :reviews, only: %i[index create]
    #     end
    #     namespace :admin do
    #       resources :orders, only: %i[index]
    #     end
    #     mount SomeRackApp, at: "/webhooks"
    #   end
    #
    # Matching: fully static paths are an O(1) hash lookup; paths with
    # :params or a trailing *glob are matched through a per-verb segment trie.
    class Router
      VERBS = %w[GET POST PUT PATCH DELETE OPTIONS HEAD].freeze

      Route = Struct.new(:verb, :path, :controller, :action, :app, :name, :param_names, keyword_init: true) do
        def target = app ? app.inspect : "#{controller}##{action}"
        def static? = param_names.empty?
      end

      class Node
        attr_accessor :route, :param, :glob

        def children = @children ||= {}
        def child(segment) = @children&.[](segment)
      end

      attr_reader :prefix, :routes

      def initialize(prefix: "", resolver: nil)
        @prefix = normalize(prefix)
        @prefix = "" if @prefix == "/"
        @resolver = resolver || method(:resolve_controller)
        @routes = []
        @static = {}
        @trees = {}
        @endpoints = {}
        @mutex = Mutex.new
      end

      def draw(&)
        Mapper.new(self).instance_exec(&)
        self
      end

      # Low-level registration; the DSL (Mapper) is built on top of it.
      def add(verb, path, controller: nil, action: nil, app: nil, name: nil)
        verb = verb.to_s.upcase
        raise ArgumentError, "unknown HTTP verb #{verb}" unless VERBS.include?(verb)
        raise ArgumentError, "route needs a controller#action or an app" unless app || (controller && action)

        full = join(@prefix, path)
        segments = split(full)
        params = segments.filter_map { |s| s[1..] if s.start_with?(":", "*") }
        route = Route.new(verb: verb, path: full, controller: controller&.to_s, action: action&.to_s, app: app,
                          name: name, param_names: params.freeze)
        insert(route, segments)
        @routes << route
        route
      end

      # Returns [route, params] or nil.
      def recognize(verb, path)
        path = normalize(path)
        if (route = @static[verb]&.[](path))
          return [route, {}]
        end

        tree = @trees[verb] or return
        segments = split(path).map { |s| Rack::Utils.unescape_path(s) }
        values = []
        route = walk(tree, segments, 0, values)
        route && [route, route.param_names.zip(values).to_h]
      end

      def allowed_verbs(path)
        VERBS.select { |verb| recognize(verb, path) }
      end

      # Rack interface.
      def call(env)
        verb = env[Rack::REQUEST_METHOD]
        path = env[Rack::PATH_INFO]
        route, params = recognize(verb, path)
        route, params = recognize("GET", path) if route.nil? && verb == "HEAD"
        return no_route(verb, path) unless route

        env[PATH_PARAMS] = params
        env[ROUTE] = route
        status, headers, body = dispatch(route, env)
        if verb == "HEAD" && route.verb != "HEAD"
          body.close if body.respond_to?(:close)
          body = []
        end
        [status, headers, body]
      end

      private

      def dispatch(route, env)
        return route.app.call(env) if route.app

        controller = @endpoints[route.controller] || @mutex.synchronize do
          @endpoints[route.controller] ||= @resolver.call(route.controller)
        end
        controller.dispatch(route.action, env)
      end

      def resolve_controller(name)
        const = "#{Inflector.camelize(name)}Controller"
        Object.const_get(const)
      rescue NameError => e
        raise unless e.name.to_s == const.split("::").last || e.message.include?(const)

        raise ConfigurationError, "route points to #{const}, which is not defined"
      end

      def no_route(verb, path)
        allowed = allowed_verbs(path)
        raise NotFound.new("No route matches #{verb} #{path}", code: "route_not_found") if allowed.empty?

        allowed << "HEAD" if allowed.include?("GET") && !allowed.include?("HEAD")
        raise MethodNotAllowed.new("#{verb} is not allowed for #{path}", headers: { "allow" => allowed.join(", ") })
      end

      def insert(route, segments)
        return insert_static(route) if route.static?

        glob = segments.last.start_with?("*") ? segments.pop : nil
        if segments.any? { |segment| segment.start_with?("*") }
          raise ArgumentError, "glob must be the last segment in #{route.path}"
        end

        node = segments.inject(@trees[route.verb] ||= Node.new) do |current, segment|
          segment.start_with?(":") ? (current.param ||= Node.new) : (current.children[segment] ||= Node.new)
        end
        slot = glob ? :glob : :route
        duplicate!(route) if node.public_send(slot)
        node.public_send(:"#{slot}=", route)
      end

      def insert_static(route)
        static = (@static[route.verb] ||= {})
        duplicate!(route) if static.key?(route.path)
        static[route.path] = route
      end

      def duplicate!(route)
        raise ArgumentError, "duplicate route #{route.verb} #{route.path}"
      end

      # Depth-first: static segments beat params, params beat globs.
      # A glob matches one or more remaining segments.
      def walk(node, segments, index, values)
        return node.route if index == segments.size

        segment = segments[index]
        if (child = node.child(segment)) && (found = walk(child, segments, index + 1, values))
          return found
        end

        if node.param
          values.push(segment)
          found = walk(node.param, segments, index + 1, values)
          return found if found

          values.pop
        end

        finish_glob(node, segments, index, values) if node.glob
      end

      def finish_glob(node, segments, index, values)
        values.push(segments[index..].join("/"))
        node.glob
      end

      def join(prefix, path)
        path = normalize(path)
        return prefix.empty? ? "/" : prefix if path == "/"

        prefix + path
      end

      def normalize(path)
        path = path.to_s
        path = "/#{path}" unless path.start_with?("/")
        path = path.squeeze("/")
        path.length > 1 ? path.chomp("/") : path
      end

      def split(path) = path.split("/").reject(&:empty?)

      # The routing DSL. Kept separate from Router so the DSL's method names
      # (get, delete, resources, ...) never collide with the router's own API.
      class Mapper
        RESOURCE_ACTIONS = {
          index: [["GET", ""]],
          create: [["POST", ""]],
          show: [["GET", "/:id"]],
          update: [["PATCH", "/:id"], ["PUT", "/:id"]],
          destroy: [["DELETE", "/:id"]]
        }.freeze

        def initialize(router, path: "", module_name: nil, controller: nil)
          @router = router
          @path = path
          @module = module_name
          @controller = controller
        end

        VERBS.each do |verb|
          define_method(verb.downcase) do |path, to: nil, action: nil, controller: nil, as: nil|
            map(verb, path, to: to, action: action, controller: controller, as: as)
          end
        end

        def scope(path = "", module: nil, &)
          Mapper.new(@router, path: @path + clean(path), module_name: join_module(binding.local_variable_get(:module)),
                              controller: @controller).instance_exec(&)
        end

        def namespace(name, &)
          scope("/#{name}", module: name.to_s, &)
        end

        # A conventional REST resource: index, create, show, update, destroy.
        def resources(name, only: nil, except: nil, path: nil, controller: nil, &block)
          actions = RESOURCE_ACTIONS.keys
          actions &= Array(only).map(&:to_sym) if only
          actions -= Array(except).map(&:to_sym) if except
          base = @path + (path ? clean(path) : "/#{Inflector.dasherize(name)}")
          controller_name = qualify(controller || name.to_s)

          actions.each do |action|
            RESOURCE_ACTIONS.fetch(action).each do |verb, suffix|
              @router.add(verb, base + suffix, controller: controller_name, action: action,
                                               name: route_name(name, action))
            end
          end
          return unless block

          ResourceMapper.new(@router, base: base, controller: controller_name, module_name: @module,
                                      param: "#{Inflector.singularize(name.to_s)}_id").instance_exec(&block)
        end

        # Mounts any Rack app under a path. The app receives the full path.
        def mount(app, at:)
          base = @path + clean(at)
          VERBS.each do |verb|
            @router.add(verb, base, app: app)
            @router.add(verb, "#{base}/*path", app: app)
          end
        end

        private

        def map(verb, path, to:, action:, controller:, as:)
          return @router.add(verb, @path + clean(path), app: to, name: as) if to.respond_to?(:call)

          if to
            controller, action = to.to_s.split("#", 2)
            raise ArgumentError, "to: must look like \"controller#action\", got #{to.inspect}" unless action
          end
          controller = controller ? qualify(controller.to_s) : @controller
          raise ArgumentError, "route #{verb} #{path} needs to: \"controller#action\"" unless controller && action

          @router.add(verb, @path + clean(path), controller: controller, action: action, name: as)
        end

        def qualify(controller) = @module && !controller.include?("/") ? "#{@module}/#{controller}" : controller
        def join_module(mod) = [@module, mod].compact.join("/").then { |m| m.empty? ? nil : m }
        def clean(path) = path.to_s.empty? || path == "/" ? "" : "/#{path.to_s.delete_prefix("/").chomp("/")}"

        def route_name(name, action)
          singular = Inflector.singularize(name.to_s)
          { index: name.to_s, show: singular }[action]&.then { |n| [@module&.tr("/", "_"), n].compact.join("_") }
        end
      end

      # DSL inside a `resources` block: member/collection routes and nesting.
      class ResourceMapper < Mapper
        def initialize(router, base:, controller:, module_name:, param:)
          super(router, path: base, module_name: module_name, controller: controller)
          @base = base
          @param = param
        end

        # Routes on a single record: /products/:id/<path>
        def member(&)
          Mapper.new(@router, path: "#{@base}/:id", module_name: @module, controller: @controller).instance_exec(&)
        end

        # Routes on the collection: /products/<path>
        def collection(&)
          Mapper.new(@router, path: @base, module_name: @module, controller: @controller).instance_exec(&)
        end

        # Nested resources: /products/:product_id/reviews
        def resources(name, **, &)
          Mapper.new(@router, path: "#{@base}/:#{@param}", module_name: @module).resources(name, **, &)
        end
      end
    end
  end
end
