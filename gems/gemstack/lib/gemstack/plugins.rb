# frozen_string_literal: true

module GemStack
  # Registry through which optional modules hook into application boot
  # without the core (or the umbrella gem) knowing about them in advance.
  #
  #   # inside a module such as gemstack/jobs:
  #   GemStack::Plugins.register(:jobs) do |app|
  #     app.config.http.middleware.use GemStack::Jobs::Middleware
  #     app.on_shutdown { GemStack::Jobs.stop }
  #   end
  #
  # Hooks run once per boot, after configuration files are loaded and before
  # the application is built, in registration order.
  module Plugins
    Plugin = Struct.new(:name, :hook)

    @registry = {}
    @mutex = Mutex.new

    class << self
      def register(name, &hook)
        raise ArgumentError, "plugin #{name.inspect} needs a block" unless hook

        @mutex.synchronize { @registry[name.to_sym] = Plugin.new(name.to_sym, hook) }
      end

      def unregister(name) = @mutex.synchronize { @registry.delete(name.to_sym) }
      def registered?(name) = @registry.key?(name.to_sym)
      def names = @registry.keys
      def each(&) = @registry.values.each(&)

      def run(app)
        each { |plugin| plugin.hook.call(app) }
      end
    end
  end
end
