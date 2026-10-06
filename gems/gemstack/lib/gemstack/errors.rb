# frozen_string_literal: true

module GemStack
  # Base class for every GemStack error.
  #
  # Errors carry an HTTP-oriented *suggestion* (`status`, `code`) so that any
  # module — including ones that know nothing about HTTP, such as a database
  # adapter — can raise an error that the HTTP layer renders correctly. Any
  # exception that responds to #status and #code is rendered this way, so
  # applications can define their own errors without subclassing these.
  class Error < StandardError
    class << self
      attr_writer :default_status, :default_code, :default_message

      def default_status = @default_status || inherited_default(:default_status, 500)
      def default_code = @default_code || inherited_default(:default_code, "internal_error")
      def default_message = @default_message || inherited_default(:default_message, "Internal Server Error")

      # Declares the status/code/message for an error class.
      def status(status, code, message)
        self.default_status = status
        self.default_code = code
        self.default_message = message
      end

      private

      def inherited_default(name, fallback) = superclass.respond_to?(name) ? superclass.public_send(name) : fallback
    end

    attr_reader :status, :code, :details, :headers

    # details: optional field => [messages] hash, rendered as `errors`.
    # headers: extra response headers (e.g. "allow" for 405, "retry-after" for 429).
    def initialize(message = nil, status: nil, code: nil, details: nil, headers: nil)
      @status = status || self.class.default_status
      @code = code || self.class.default_code
      @details = details
      @headers = headers || {}
      super(message || self.class.default_message)
    end

    # Whether the message is safe to show to API clients. Server errors are
    # not: their messages may contain internal information.
    def expose_message? = status < 500
  end

  # Raised for invalid framework or application configuration.
  class ConfigurationError < Error; end

  class BadRequest < Error
    status 400, "bad_request", "Bad Request"
  end

  class Unauthorized < Error
    status 401, "unauthorized", "Unauthorized"
  end

  class Forbidden < Error
    status 403, "forbidden", "Forbidden"
  end

  class NotFound < Error
    status 404, "not_found", "Not Found"
  end

  class MethodNotAllowed < Error
    status 405, "method_not_allowed", "Method Not Allowed"
  end

  class Conflict < Error
    status 409, "conflict", "Conflict"
  end

  class PayloadTooLarge < Error
    status 413, "payload_too_large", "Payload Too Large"
  end

  class UnsupportedMediaType < Error
    status 415, "unsupported_media_type", "Unsupported Media Type"
  end

  class ValidationError < Error
    status 422, "validation_failed", "Validation failed"

    # Without a message, it lists the errors — "Validation failed: name is
    # required, price must be greater than 0" — so logs, consoles and clients
    # that only show the message say what failed.
    def initialize(message = nil, errors: {}, **)
      super(message || self.class.summary(errors), details: errors, **)
    end

    def self.summary(errors)
      list = errors.to_h.flat_map do |field, messages|
        Array(messages).map { |text| %w[base _base].include?(field.to_s) ? text : "#{field} #{text}" }
      end
      list.empty? ? default_message : "#{default_message}: #{list.join(", ")}"
    end

    def errors = details
  end

  class TooManyRequests < Error
    status 429, "too_many_requests", "Too Many Requests"
  end

  class ServiceUnavailable < Error
    status 503, "service_unavailable", "Service Unavailable"
  end
end
