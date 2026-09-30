# frozen_string_literal: true

module GemStack
  # Translates third-party exceptions into GemStack errors, so modules can
  # give library errors an HTTP meaning without depending on the HTTP layer:
  #
  #   GemStack::ErrorMapping.register(Sequel::NoMatchingRow) { GemStack::NotFound.new }
  #   GemStack::ErrorMapping.register(Stripe::CardError) { |e| GemStack::Error.new(e.message, status: 402, code: "card_declined") }
  #
  # The HTTP error renderer consults this registry before rendering. The most
  # recently registered matching class wins, so applications can override
  # module defaults.
  module ErrorMapping
    @mappings = []
    @mutex = Mutex.new

    class << self
      def register(exception_class, &translator)
        raise ArgumentError, "ErrorMapping.register needs a block" unless translator

        @mutex.synchronize { @mappings.unshift([exception_class, translator]) }
      end

      def unregister(exception_class)
        @mutex.synchronize { @mappings.reject! { |klass, _| klass == exception_class } }
      end

      # Returns the translated error, or the original exception if no mapping applies.
      def translate(exception)
        _, translator = @mappings.find { |klass, _| exception.is_a?(klass) }
        return exception unless translator

        translator.call(exception) || exception
      end
    end
  end
end
