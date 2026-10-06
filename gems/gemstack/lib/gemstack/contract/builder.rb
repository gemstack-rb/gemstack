# frozen_string_literal: true

module GemStack
  module Contract
    # Turns the route table into a language-neutral contract (IR):
    #
    #   {
    #     api_path: "/api",
    #     types: { "Product" => { fields: [{ name:, type:, nullable:, optional: }] }, ... },
    #     resources: [{ name: "products", endpoints: [{ name: "list", verb: "GET", path: "/products",
    #                   params: [], body: nil, query: nil, response: { array: { ref: "Product" } } }] }],
    #     warnings: [...]
    #   }
    #
    # A type reference is { scalar: :string }, { ref: "Product" }, { array: ref },
    # { object: [fields] } (anonymous nested object) or { unknown: true }.
    #
    # Response conventions (overridable with `returns` in the controller):
    #   index → [<Resource>Serializer], show/create/update → <Resource>Serializer,
    #   destroy → no body, anything else → unknown (with a warning).
    class Builder
      # Names the generated TypeScript defines itself.
      RESERVED_TYPES = %w[Paginated PaginationMeta PaginationQuery RequestOptions].freeze

      METHOD_NAMES = { "index" => "list", "show" => "get", "create" => "create", "update" => "update",
                       "destroy" => "delete" }.freeze
      VERB_PREFERENCE = %w[GET POST PATCH PUT DELETE].freeze

      def initialize(routes:, api_path:)
        @routes = routes
        @api_path = api_path.to_s
        @types = {}
        @warnings = []
      end

      def build
        result = build_contract
        clash = result[:types].keys & RESERVED_TYPES
        unless clash.empty?
          raise ConfigurationError, "API type name(s) #{clash.join(", ")} are reserved by the generated TypeScript; " \
                                    "rename the serializer/schema or set its type_name"
        end
        result
      end

      def build_contract
        resources = @routes.select(&:controller).group_by(&:controller).sort.filter_map do |controller_name, routes|
          controller = resolve(controller_name) or next
          endpoints = routes.group_by(&:action).map do |action, action_routes|
            endpoint(controller, action, action_routes)
          end
          { name: controller_name, endpoints: endpoints.compact.sort_by { |e| [e[:path], e[:name]] } }
        end
        { api_path: @api_path, types: @types.sort.to_h, resources: resources, warnings: @warnings }
      end

      private

      def resolve(controller_name)
        const = "#{Inflector.camelize(controller_name)}Controller"
        Object.const_get(const)
      rescue NameError
        @warnings << "#{const} is not defined; its routes are left out of the contract"
        nil
      end

      def endpoint(controller, action, routes)
        route = routes.min_by { |r| VERB_PREFERENCE.index(r.verb) || 99 }
        path = route.path.delete_prefix(@api_path)
        path = "/" if path.empty?
        schema = controller.input_schemas[action]
        input = schema && schema_ref(schema, "#{resource_name(controller)}#{Inflector.camelize(action)}Input")
        get = %w[GET HEAD].include?(route.verb)
        response = response_ref(controller, action)
        {
          name: METHOD_NAMES.fetch(action) { lower_camel(action) }, action: action, verb: route.verb, path: path,
          params: route.param_names.dup, body: get ? nil : input, query: get ? input : nil,
          response: response, paginated: response.is_a?(Hash) && response.key?(:page)
        }
      end

      def response_ref(controller, action)
        if controller.response_types.key?(action)
          type = controller.response_types[action]
          return type.nil? ? nil : type_ref(type)
        end

        serializer = conventional_serializer(controller)
        case action
        when "index" then serializer ? { array: serializer_ref(serializer) } : unknown(controller, action)
        when "show", "create", "update" then serializer ? serializer_ref(serializer) : unknown(controller, action)
        when "destroy" then nil
        else unknown(controller, action)
        end
      end

      def unknown(controller, action)
        @warnings << "#{controller.name}##{action}: response type unknown (add `returns :#{action}, SomeSerializer`)"
        { unknown: true }
      end

      # ProductsController → ProductSerializer (Admin::ProductsController tries Admin::ProductSerializer first).
      def conventional_serializer(controller)
        parts = controller.name.delete_suffix("Controller").split("::")
        singular = Inflector.singularize(parts.last)
        candidates = ["#{(parts[0...-1] + [singular]).join("::")}Serializer", "#{singular}Serializer"].uniq
        candidates.each do |name|
          klass = Object.const_get(name) if Object.const_defined?(name)
          return klass if klass.is_a?(Class) && klass <= Serializer
        rescue NameError
          next
        end
        nil
      end

      def resource_name(controller)
        Inflector.singularize(controller.name.delete_suffix("Controller").split("::").join)
      end

      def type_ref(type)
        case type
        when HTTP::Page::Type then { page: type_ref(type.item) }
        when Array then { array: type_ref(type.first) }
        when Class
          return serializer_ref(type) if type <= Serializer
          return schema_ref(type, type.name.to_s.split("::").join) if type <= Schema

          { scalar: Types.fetch(type).name }
        else { scalar: Types.fetch(type).name }
        end
      end

      def serializer_ref(serializer)
        name = serializer.type_name
        unless @types.key?(name)
          @types[name] = :pending # guards against recursive serializers
          fields = serializer.resolved_attributes.map do |attr|
            if attr[:type] == :json && !serializer.attributes_list[attr[:name]].type
              @warnings << "#{serializer.name}##{attr[:name]}: type unknown, emitted as unknown"
            end
            type = enum_values(serializer, attr)&.then { |values| { enum: values } } || type_ref(attr[:type])
            { name: attr[:name].to_s, type: type, nullable: attr[:nullable], optional: false }
          end
          @types[name] = { fields: fields }
        end
        { ref: name }
      end

      # An inferred string attribute backed by a model enum is a union type.
      def enum_values(serializer, attr)
        return nil unless attr[:type] == :string && serializer.attributes_list[attr[:name]]&.type.nil?

        field = serializer.model&.gemstack_fields&.[](attr[:name])
        field && field.options[:enum]
      end

      def schema_ref(schema, fallback_name)
        name = schema.type_name || fallback_name
        @types[name] ||= { fields: schema_fields(schema) }
        { ref: name }
      end

      def schema_fields(schema)
        schema.fields.values.map do |field|
          type = if field.schema then { object: schema_fields(field.schema) }
                 elsif field.rules[:enum] then { enum: field.rules[:enum].map(&:to_s) }
                 else { scalar: field.type }
                 end
          type = { array: type } if field.array
          { name: field.name.to_s, type: type, nullable: field.nullable, optional: field.ts_optional? }
        end
      end

      def lower_camel(name)
        camel = Inflector.camelize(name)
        camel[0].downcase + camel[1..]
      end
    end
  end
end
