# frozen_string_literal: true

module GemStack
  module Contract
    # Development API docs:
    #   GET <api_path>/docs               interactive page (self-contained, no CDN)
    #   GET <api_path>/docs/openapi.json  OpenAPI 3.1 built from the current routes
    # Rebuilt on every request, so it always matches the code after a reload.
    class Docs
      PAGE = File.read(File.join(__dir__, "docs", "index.html")).freeze
      CSP = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; " \
            "img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

      def initialize(app, application)
        @app = app
        @application = application
      end

      def call(env)
        path = env[Rack::PATH_INFO]
        base = "#{@application.config.http.api_path}/docs"
        return @app.call(env) unless env[Rack::REQUEST_METHOD] == "GET" && [base, "#{base}/",
                                                                            "#{base}/openapi.json"].include?(path)

        path.end_with?(".json") ? openapi : page(base)
      end

      private

      def openapi
        contract = Builder.new(routes: @application.routes, api_path: @application.config.http.api_path).build
        body = JSON.generate(OpenAPI.new(contract).document.merge("x-gemstack-warnings" => contract[:warnings]))
        [200, { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" }, [body]]
      end

      def page(base)
        title = Rack::Utils.escape_html(GemStack.config.name.to_s)
        html = PAGE.gsub("__OPENAPI_URL__", "#{base}/openapi.json").gsub("__TITLE__", title)
        headers = { "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store",
                    "content-security-policy" => CSP }
        [200, headers, [html]]
      end
    end
  end
end
