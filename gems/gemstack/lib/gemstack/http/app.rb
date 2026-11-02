# frozen_string_literal: true

module GemStack
  module HTTP
    # The Rack application: the compiled middleware stack in front of the
    # router. Built once; the router can be replaced (for reloading) without
    # rebuilding the stack.
    class App
      attr_reader :config, :codec
      attr_accessor :router

      def initialize(config:, router:)
        @config = config
        @router = router
        @codec = JSONCodec.resolve(config.json, max_nesting: config.json_max_nesting)
        @stack = config.middleware.build(method(:endpoint))
      end

      def call(env) = @stack.call(env)

      private

      def endpoint(env)
        env[JSON_CODEC] = @codec
        env[CONFIG] = @config
        @router.call(env)
      end
    end

    # Dispatches a reserved Rack app before the API middleware/router. The
    # mount is matched on a segment boundary, so /jobs-extra remains an API
    # request (and follows the normal route-not-found behavior).
    class PathDispatch
      def initialize(app, path:, mounted_app:)
        @app = app
        @path = path
        @mounted_app = mounted_app
      end

      def call(env)
        path = env[Rack::PATH_INFO].to_s
        script_name = env[Rack::SCRIPT_NAME].to_s
        return @mounted_app.call(env) if mounted?(path) || script_name.end_with?(@path)

        @app.call(env)
      end

      private

      def mounted?(path) = path == @path || path.start_with?("#{@path}/")
    end
  end
end
