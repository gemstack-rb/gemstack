# frozen_string_literal: true

module GemStack
  module Contract
    # OpenAPI 3.1 document from the contract IR.
    class OpenAPI
      ERROR_SCHEMA = {
        type: "object",
        required: ["error"],
        properties: {
          error: {
            type: "object", required: %w[code message],
            properties: { code: { type: "string" }, message: { type: "string" }, request_id: { type: "string" } }
          },
          errors: { type: "object", additionalProperties: { type: "array", items: { type: "string" } } }
        }
      }.freeze

      def initialize(contract, title: GemStack.config.name, version: GemStack::VERSION)
        @contract = contract
        @title = title
        @version = version
      end

      def document
        {
          openapi: "3.1.0",
          info: { title: @title, version: @version },
          paths: paths,
          components: { schemas: schemas.merge("Error" => ERROR_SCHEMA) }
        }
      end

      PAGE_PARAMETERS = %w[page per_page].map do |name|
        { name: name, in: "query", required: false, schema: { type: "integer", minimum: 1 } }
      end.freeze

      private

      def paths
        @contract[:resources].flat_map { |resource| resource[:endpoints].map { |e| [resource, e] } }
                             .group_by { |_, e| openapi_path(e[:path]) }
                             .transform_values do |pairs|
          pairs.to_h do |resource, e|
            [e[:verb].downcase, operation(resource, e)]
          end
        end
      end

      def operation(resource, endpoint)
        op = {
          operationId: "#{resource[:name].tr("/", "_")}.#{endpoint[:name]}",
          tags: [resource[:name]],
          parameters: endpoint[:params].map { |p| { name: p, in: "path", required: true, schema: { type: "string" } } },
          responses: responses(endpoint)
        }
        op[:parameters].concat(query_parameters(endpoint[:query])) if endpoint[:query]
        op[:parameters].concat(PAGE_PARAMETERS) if endpoint[:paginated]
        if endpoint[:body]
          op[:requestBody] =
            { required: true, content: { "application/json" => { schema: schema_for(endpoint[:body]) } } }
        end
        op
      end

      def responses(endpoint)
        success = endpoint[:verb] == "POST" ? "201" : "200"
        ok = if endpoint[:response]
               { success => { description: "OK",
                              content: { "application/json" => { schema: schema_for(endpoint[:response]) } } } }
             else
               { "204" => { description: "No Content" } }
             end
        error = { description: "Error",
                  content: { "application/json" => { schema: { "$ref": "#/components/schemas/Error" } } } }
        ok.merge("default" => error)
      end

      def query_parameters(ref)
        fields = ref[:ref] ? @contract[:types].dig(ref[:ref], :fields) : []
        Array(fields).map do |field|
          { name: field[:name], in: "query", required: !field[:optional], schema: schema_for(field[:type]) }
        end
      end

      def schemas
        @contract[:types].transform_values { |type| object_schema(type[:fields]) }
      end

      def object_schema(fields)
        properties = fields.to_h do |field|
          schema = schema_for(field[:type])
          schema = { oneOf: [schema, { type: "null" }] } if field[:nullable]
          [field[:name], schema]
        end
        { type: "object", properties: properties, required: fields.reject { |f| f[:optional] }.map { |f| f[:name] } }
      end

      def schema_for(ref)
        if ref[:scalar] then Types.fetch(ref[:scalar]).openapi.dup
        elsif ref[:ref] then { "$ref": "#/components/schemas/#{ref[:ref]}" }
        elsif ref[:array] then { type: "array", items: schema_for(ref[:array]) }
        elsif ref[:page] then page_schema(ref[:page])
        elsif ref[:object] then object_schema(ref[:object])
        else {}
        end
      end

      def page_schema(item)
        meta = %w[page per_page total total_pages].to_h { |key| [key, { type: "integer" }] }
        {
          type: "object", required: %w[data meta],
          properties: {
            data: { type: "array", items: schema_for(item) },
            meta: { type: "object", required: meta.keys, properties: meta }
          }
        }
      end

      def openapi_path(path) = "#{@contract[:api_path]}#{path.gsub(/[:*](\w+)/, '{\1}')}"
    end
  end
end
