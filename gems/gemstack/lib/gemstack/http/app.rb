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
  end
end
