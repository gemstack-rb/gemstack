# frozen_string_literal: true

require "rack"
require "gemstack/core"
require "gemstack/schema"

module GemStack
  # The API layer: a Rack application composed of a middleware stack and a
  # router that dispatches to controllers.
  module HTTP
    # Rack env keys owned by GemStack.
    REQUEST_ID = "gemstack.request_id"
    PATH_PARAMS = "gemstack.path_params"
    JSON_CODEC = "gemstack.json"
    ROUTE = "gemstack.route"
    CONFIG = "gemstack.http_config"
  end
end

require_relative "http/json_codec"
require_relative "http/error_renderer"
require_relative "http/error_page"
require_relative "http/middleware_stack"
require_relative "http/middleware/request_id"
require_relative "http/middleware/request_logger"
require_relative "http/middleware/compression"
require_relative "http/middleware/error_handler"
require_relative "http/middleware/security_headers"
require_relative "http/middleware/cors"
require_relative "http/middleware/body_limit"
require_relative "http/middleware/health_check"
require_relative "http/middleware/etags"
require_relative "http/config"
require_relative "http/request"
require_relative "http/params"
require_relative "http/router"
require_relative "http/page"
require_relative "http/controller"
require_relative "http/app"

GemStack::Config.namespace(:http, GemStack::HTTP::Config)
