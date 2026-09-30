# frozen_string_literal: true

module GemStack
  module HTTP
    # An ordered, editable list of Rack middleware, compiled once into a
    # nested Rack app when the application is built.
    #
    #   config.http.middleware.use Rack::Attack
    #   config.http.middleware.insert_before GemStack::HTTP::Middleware::ErrorHandler, MyTiming
    #   config.http.middleware.swap GemStack::HTTP::Middleware::RequestLogger, MyLogger
    #   config.http.middleware.delete GemStack::HTTP::Middleware::SecurityHeaders
    #
    # Targets are middleware classes or integer positions. Any Rack
    # middleware (`new(app, *args)`, `#call(env)`) works.
    class MiddlewareStack
      include Enumerable

      Entry = Struct.new(:klass, :args, :kwargs, :block) do
        def build(app) = klass.new(app, *args, **kwargs, &block)
        def name = klass.respond_to?(:name) && klass.name ? klass.name : klass.inspect
      end

      def self.default(config)
        new.tap do |stack|
          stack.use Middleware::RequestId, config
          stack.use Middleware::RequestLogger
          stack.use Middleware::Compression, config
          stack.use Middleware::ErrorHandler, config
          stack.use Middleware::SecurityHeaders, config
          stack.use Middleware::Cors, config
          stack.use Middleware::BodyLimit, config
          stack.use Middleware::HealthCheck, config
          stack.use Middleware::ETags, config
        end
      end

      def initialize
        @entries = []
      end

      def use(klass, *args, **kwargs, &block)
        @entries << Entry.new(klass, args, kwargs, block)
        self
      end

      def unshift(klass, *args, **kwargs, &block)
        @entries.unshift(Entry.new(klass, args, kwargs, block))
        self
      end

      def insert_before(target, klass, *args, **kwargs, &block)
        @entries.insert(index!(target), Entry.new(klass, args, kwargs, block))
        self
      end

      def insert_after(target, klass, *args, **kwargs, &block)
        @entries.insert(index!(target) + 1, Entry.new(klass, args, kwargs, block))
        self
      end

      def swap(target, klass, *args, **kwargs, &block)
        @entries[index!(target)] = Entry.new(klass, args, kwargs, block)
        self
      end

      def delete(target)
        @entries.delete_at(index!(target))
        self
      end

      def include?(klass) = @entries.any? { |entry| entry.klass == klass }
      def each(&) = @entries.each(&)
      def size = @entries.size
      def names = @entries.map(&:name)

      # Wraps endpoint so that the first middleware in the list runs first.
      def build(endpoint)
        @entries.reverse.inject(endpoint) { |app, entry| entry.build(app) }
      end

      def initialize_copy(source)
        super
        @entries = source.to_a.dup
      end

      private

      def index!(target)
        index = target.is_a?(Integer) ? target : @entries.index { |entry| entry.klass == target }
        raise ArgumentError, "no middleware #{target.inspect} in the stack" unless index && @entries[index]

        index
      end
    end
  end
end
