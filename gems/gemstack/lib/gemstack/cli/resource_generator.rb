# frozen_string_literal: true

module GemStack
  class CLI < Thor
    # Generates a vertical slice for a ResourceSpec from composable parts:
    #
    #   migration   db/migrations/<ts>_create_<table>.rb
    #   model       app/models/<name>.rb + test/models/<name>_test.rb
    #   serializer  app/serializers/<name>_serializer.rb
    #   controller  app/controllers/<plural>_controller.rb + test + routes
    #   frontend    Next.js pages, components and TanStack Query hooks
    #
    # `generate model` uses [migration, model, serializer]; `generate resource`
    # uses all parts (minus backend or frontend with --frontend-only/--api-only).
    # Every template can be overridden in lib/templates/gemstack/resource/<part>/.
    class ResourceGenerator < Generator
      PARTS = %i[migration model serializer controller frontend].freeze

      # Frontend files that only make sense for some actions.
      REQUIRES = {
        "new/page.tsx" => %w[create], "[id]/edit/page.tsx" => %w[update], "[id]/page.tsx" => %w[show],
        "Card.tsx" => %w[show], "Form.tsx" => %w[create update]
      }.freeze

      attr_reader :spec, :timestamp, :tests

      def initialize(spec, root:, parts: PARTS, tests: true, output: $stdout, force: false, timestamp: nil)
        super(output: output, force: force)
        @spec = spec
        @root = root
        @parts = parts
        @tests = tests
        @timestamp = timestamp || Generator.migration_timestamp(root)
      end

      def run
        @manifest = GenerationManifest.new(@root)
        ensure_base_classes(@root, *(%i[model serializer] & @parts))
        @parts.each { |part| render_part(part) }
        add_routes if @parts.include?(:controller)
        self
      ensure
        @manifest&.save
      end

      # --- template helpers -------------------------------------------------

      def fields = spec.fields
      def class_name = spec.class_name
      def input_type = spec.action?(:create) ? "#{class_name}Input" : "#{class_name}UpdateInput"

      # Sequel schema DSL per field type ("%s" is the column name).
      COLUMN_TYPES = {
        "string" => "String :%s", "text" => "String :%s, text: true", "integer" => "Integer :%s",
        "bigint" => "Bignum :%s", "float" => "Float :%s", "decimal" => "BigDecimal :%s, size: [12, 2]",
        "date" => "Date :%s", "datetime" => "column :%s, :timestamptz", "uuid" => "column :%s, :uuid",
        "json" => "column :%s, :jsonb"
      }.freeze

      def migration_column(field)
        null = field.required? ? ", null: false" : ""
        case field.type
        when "references"
          "foreign_key :#{field.column}, :#{field.referenced_table}, type: :Bignum#{null}, on_delete: :restrict"
        when "boolean" then "TrueClass :#{field.name}, null: false, default: false"
        else
          unique = field.unique && field.type != "json" ? ", unique: true" : ""
          format(COLUMN_TYPES.fetch(field.type), field.name) + null + unique
        end
      end

      def model_field(field)
        options = []
        options << "null: false" if field.required?
        options << "null: false, default: false" if field.type == "boolean"
        options << "size: 255" if field.type == "string"
        ["field :#{field.column}, :#{field.model_type}", *options].join(", ")
      end

      def ts_value_type(field) = field.type == "boolean" ? "boolean" : "string"

      # Expression turning a record (possibly undefined) into a form value.
      def form_initial(field)
        attr = "record?.#{field.column}"
        case field.type
        when "boolean" then "#{attr} ?? false"
        when "integer", "bigint", "float", "references" then "String(#{attr} ?? \"\")"
        when "datetime" then "(#{attr} ?? \"\").slice(0, 16)"
        when "json" then "#{attr} == null ? \"\" : JSON.stringify(#{attr}, null, 2)"
        else "#{attr} ?? \"\""
        end
      end

      # Expression turning a form value into an API input value.
      def form_output(field)
        value = "values.#{field.column}"
        return value if field.type == "boolean"

        converted =
          case field.type
          when "integer", "bigint", "float", "references" then "Number(#{value})"
          when "json" then "parseJson(#{value})"
          else value
          end
        blank = field.required? ? "\"\"" : "null"
        converted == value && field.required? ? value : "#{value} === \"\" ? #{blank} : #{converted}"
      end

      def form_control(field)
        key = field.column
        common = %(id="#{field.column}" name="#{field.column}")
        required = field.required? ? " required" : ""
        case field.type
        when "boolean"
          %(<input #{common} type="checkbox" checked={values.#{key}} onChange={set("#{key}")} />)
        when "text", "json"
          %(<textarea #{common} rows={4} value={values.#{key}} onChange={set("#{key}")}#{required} />)
        else
          attrs = { "integer" => %(type="number" step="1"), "bigint" => %(type="number" step="1"),
                    "references" => %(type="number" step="1"), "float" => %(type="number" step="any"),
                    "decimal" => %(type="text" inputMode="decimal"), "date" => %(type="date"),
                    "datetime" => %(type="datetime-local") }.fetch(field.type, %(type="text"))
          %(<input #{common} #{attrs} value={values.#{key}} onChange={set("#{key}")}#{required} />)
        end
      end

      def table_fields = fields.first(4)
      def uses_json? = fields.any? { |f| f.type == "json" }

      private

      def render_part(part)
        return if part == :migration && existing_migration?

        template_files("resource/#{part}", override_root: @root).sort.each do |rel, source|
          next if skip?(part, rel)

          target = File.join(@root, substitute(rel.delete_suffix(".tt")))
          content = render(File.read(source, encoding: "UTF-8"), source)
          if rel == "frontend/lib/format.ts"
            write(target, content) # shared by every resource
          else
            write_tracked(target, content, owner: owner_for(part))
          end
        end
      end

      def existing_migration?
        paths = Dir.glob(File.join(@root, "db/migrations/*_create_#{spec.table}.rb"))
        paths.each { |path| status("keep", path, "existing create migration; use a new migration for schema changes") }
        !paths.empty?
      end

      def owner_for(part)
        return "controller:#{spec.plural}" if part == :controller

        "#{part == :frontend ? "resource" : "model"}:#{spec.file_name}"
      end

      def skip?(part, rel)
        return true if !tests && rel.start_with?("test/")
        return false unless part == :frontend

        requirement = REQUIRES.find { |suffix, _| rel.delete_suffix(".tt").end_with?(suffix) }&.last
        requirement ? requirement.none? { |action| spec.action?(action) } : false
      end

      def substitute(path)
        path.gsub(/%(\w+)%/) do
          key = ::Regexp.last_match(1)
          key == "timestamp" ? timestamp : spec.public_send(key)
        end
      end

      def add_routes
        path = File.join(@root, "config/routes.rb")
        return status("skip", path, "not found — add `resources :#{spec.plural}` manually") unless File.file?(path)

        only = spec.crud? ? "" : ", only: %i[#{spec.actions.join(" ")}]"
        line = "resources :#{spec.plural}#{only}"
        @manifest.absolute("config/routes.rb")
        content = File.read(path, encoding: "UTF-8")
        return status("identical", path) if content.match?(/^\s*resources :#{spec.plural}\b/)
        unless content.match?(ControllerGenerator::ROUTES_BLOCK)
          return status("skip", path, "no `GemStack.routes do` block — add `#{line}`")
        end

        File.write(path, content.sub(ControllerGenerator::ROUTES_BLOCK) { |open| "#{open}  #{line}\n" })
        @manifest.record_route("  #{line}\n", owner: "controller:#{spec.plural}")
        status("route", path, line)
      end
    end
  end
end
