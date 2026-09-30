# frozen_string_literal: true

module GemStack
  module HTTP
    # Rack::Request plus GemStack conveniences. Bodies are parsed lazily:
    # nothing is read from the socket until params or #json is used.
    class Request < Rack::Request
      JSON_TYPE = %r{\Aapplication/(?:[\w.+-]+\+)?json\b}i

      def request_id = get_header(REQUEST_ID)
      def path_params = get_header(PATH_PARAMS) || {}
      def route = get_header(ROUTE)

      def json?
        JSON_TYPE.match?(content_type.to_s)
      end

      # The parsed JSON body (any JSON value), or nil for an empty body.
      # Raises BadRequest for malformed JSON or excessive nesting.
      def json
        return @json if defined?(@json)

        raw = body&.read.to_s
        body&.rewind if body.respond_to?(:rewind)
        @json = raw.strip.empty? ? nil : codec.load(raw)
      rescue ::JSON::NestingError
        raise BadRequest.new("JSON body is nested too deeply", code: "invalid_json")
      rescue ::JSON::ParserError, EncodingError
        raise BadRequest.new("Request body is not valid JSON", code: "invalid_json")
      end

      # Parameters from the body: a JSON object, or form/multipart fields.
      # Non-object JSON bodies (arrays, scalars) are available via #json.
      def body_params
        @body_params ||=
          if json?
            value = json
            value.is_a?(Hash) ? value : {}
          elsif form_data? || parseable_data?
            self.POST
          else
            {}
          end
      end

      # Query, then body, then path parameters (later sources win).
      def all_params
        query = self.GET
        body = body_params
        path = path_params
        return query if body.empty? && path.empty?

        query.merge(body).merge(path)
      rescue Rack::QueryParser::ParameterTypeError, Rack::QueryParser::InvalidParameterError,
             Rack::Multipart::MultipartPartLimitError => e
        raise BadRequest.new(e.message, code: "invalid_parameters")
      end

      private

      def codec = get_header(JSON_CODEC) || JSONCodec.default
    end
  end
end
