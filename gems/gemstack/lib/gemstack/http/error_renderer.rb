# frozen_string_literal: true

require "json"

module GemStack
  module HTTP
    # Turns an exception into the standard JSON error envelope:
    #
    #   {"error": {"code": "not_found", "message": "Not Found", "request_id": "..."},
    #    "errors": {"name": ["is required"]}}
    #
    # Any exception responding to #status and #code is rendered with that
    # status. Everything else is a 500 whose message is hidden unless
    # show_exceptions is on.
    module ErrorRenderer
      BACKTRACE_LINES = 30

      module_function

      def render(exception, request_id: nil, show_exceptions: false)
        original = exception
        exception = ErrorMapping.translate(exception)
        status, code, message = describe(exception)
        body = { error: { code: code, message: message, request_id: request_id }.compact }
        details = exception.respond_to?(:details) ? exception.details : nil
        body[:errors] = details if details && !details.empty?
        body[:exception] = debug_info(original) if show_exceptions && status >= 500

        headers = { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" }
        headers.merge!(exception.headers) if exception.respond_to?(:headers) && exception.headers
        [status, headers, [::JSON.generate(body)]]
      end

      def describe(exception)
        if exception.respond_to?(:status) && exception.respond_to?(:code) && exception.status.is_a?(Integer)
          status = exception.status
          exposed = exception.respond_to?(:expose_message?) ? exception.expose_message? : status < 500
          message = exposed ? exception.message : Rack::Utils::HTTP_STATUS_CODES.fetch(status, "Error")
          [status, exception.code.to_s, message]
        else
          [500, "internal_error", "Internal Server Error"]
        end
      end

      # 404 => "not_found"; unknown statuses => "error"
      def code_for(status)
        Rack::Utils::SYMBOL_TO_STATUS_CODE.key(status)&.name || "error"
      end

      def debug_info(exception)
        {
          class: exception.class.name,
          message: exception.message,
          backtrace: Array(exception.backtrace).first(BACKTRACE_LINES)
        }
      end

      def json_error(status, code, message, request_id: nil, headers: {})
        render(GemStack::Error.new(message, status: status, code: code, headers: headers), request_id: request_id)
      end
    end
  end
end
