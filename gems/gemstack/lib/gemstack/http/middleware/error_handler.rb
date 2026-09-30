# frozen_string_literal: true

module GemStack
  module HTTP
    module Middleware
      # The exception boundary. Everything raised below it becomes a JSON
      # error response; server errors are logged with their backtrace.
      # Internals (class, message, backtrace) reach the client only when
      # config.http.show_exceptions is on (development/test by default).
      class ErrorHandler
        def initialize(app, config)
          @app = app
          @show_exceptions = config.show_exceptions
        end

        def call(env)
          @app.call(env)
        rescue StandardError, ScriptError => e # ScriptError: syntax errors while reloading in development
          response = ErrorRenderer.render(e, request_id: env[REQUEST_ID], show_exceptions: @show_exceptions)
          return response if response[0] < 500

          report(e, env)
          # Development: a browser opening the URL gets a readable page.
          @show_exceptions && ErrorPage.browser?(env) ? ErrorPage.render(e, env, request_id: env[REQUEST_ID]) : response
        end

        private

        def report(exception, env)
          GemStack.logger.error(
            "#{exception.class}: #{exception.message}",
            id: env[REQUEST_ID],
            backtrace: Array(exception.backtrace).first(ErrorRenderer::BACKTRACE_LINES)
          )
        end
      end
    end
  end
end
