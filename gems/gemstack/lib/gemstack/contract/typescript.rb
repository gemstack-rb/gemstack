# frozen_string_literal: true

module GemStack
  module Contract
    # Emits TypeScript from the contract IR:
    #   types.ts          one `export type` per serializer / input schema
    #   <resource>.ts     a typed client object per controller
    #   index.ts          re-exports everything
    #
    # Shapes are type aliases (not interfaces) so they are assignable to the
    # client's Query record type.
    class TypeScript
      def initialize(contract, client_import: "@/lib/gemstack/client")
        @contract = contract
        @client_import = client_import
      end

      def files
        files = { "types.ts" => types_file }
        @contract[:resources].each { |resource| files["#{file_base(resource)}.ts"] = resource_file(resource) }
        files["index.ts"] = index_file
        files
      end

      PAGE_TYPES = <<~TS
        /** The pagination envelope returned by `paginate` in controllers. */
        export type PaginationMeta = {
          page: number;
          per_page: number;
          total: number;
          total_pages: number;
        };

        export type Paginated<T> = {
          data: T[];
          meta: PaginationMeta;
        };

        export type PaginationQuery = {
          page?: number;
          per_page?: number;
        };
      TS

      private

      def header = "// #{HEADER}\n"

      def types_file
        body = @contract[:types].map do |name, type|
          "export type #{name} = #{object_type(type[:fields], 0)};\n"
        end
        body.unshift(PAGE_TYPES) if paginated?
        # No types yet (a new app): still a module, or `export type * from "./types"` fails to compile.
        body << "export {};\n" if body.empty?
        "#{header}\n#{body.join("\n")}"
      end

      def paginated? = @contract[:resources].any? { |r| r[:endpoints].any? { |e| e[:paginated] } }

      def object_type(fields, depth)
        return "Record<string, never>" if fields.empty?

        pad = "  " * (depth + 1)
        lines = fields.map do |field|
          type = ts_type(field[:type], depth + 1)
          type = "#{type} | null" if field[:nullable]
          "#{pad}#{property(field[:name])}#{"?" if field[:optional]}: #{type};"
        end
        "{\n#{lines.join("\n")}\n#{"  " * depth}}"
      end

      def ts_type(ref, depth = 0)
        if ref[:scalar] then Types.fetch(ref[:scalar]).ts
        elsif ref[:ref] then ref[:ref]
        elsif ref[:enum] then ref[:enum].map { |value| JSON.generate(value) }.join(" | ")
        elsif ref[:array]
          inner = ts_type(ref[:array], depth)
          inner.match?(/\A[\w.]+\z/) ? "#{inner}[]" : "Array<#{inner}>"
        elsif ref[:page] then "Paginated<#{ts_type(ref[:page], depth)}>"
        elsif ref[:object] then object_type(ref[:object], depth)
        else "unknown"
        end
      end

      def property(name) = name.match?(/\A[A-Za-z_$][\w$]*\z/) ? name : name.inspect

      def resource_file(resource)
        refs = []
        methods = resource[:endpoints].map { |endpoint| client_method(endpoint, refs) }
        imports = refs.uniq.sort
        lines = [header]
        lines << %(import { api, type RequestOptions } from "#{@client_import}";)
        lines << %(import type { #{imports.join(", ")} } from "./types";) unless imports.empty?
        lines << ""
        lines << "const segment = (value: string | number) => encodeURIComponent(String(value));"
        lines << ""
        lines << "export const #{export_name(resource)} = {"
        lines.concat(methods)
        lines << "};"
        "#{lines.join("\n")}\n"
      end

      def client_method(endpoint, refs)
        args = endpoint[:params].map { |param| "#{camel(param)}: string | number" }
        collect_refs(endpoint[:body], refs)
        collect_refs(endpoint[:query], refs)
        collect_refs(endpoint[:response], refs)
        args << "data: #{ts_type(endpoint[:body])}" if endpoint[:body]
        args << query_arg(endpoint) if endpoint[:query] || endpoint[:paginated]
        refs << "PaginationQuery" if endpoint[:paginated]
        args << "options?: RequestOptions"
        response = endpoint[:response] ? ts_type(endpoint[:response]) : "void"
        call = "api.#{client_verb(endpoint[:verb])}<#{response}>(#{call_args(endpoint)})"
        "  /** #{endpoint[:verb]} #{@contract[:api_path]}#{endpoint[:path]} */\n  " \
          "#{endpoint[:name]}: (#{args.join(", ")}) => #{call},"
      end

      # Paginated lists take an optional { page, per_page } query, combined
      # with the action's own query schema when there is one.
      def query_arg(endpoint)
        return "query: #{ts_type(endpoint[:query])}" unless endpoint[:paginated]
        return "query?: PaginationQuery" unless endpoint[:query]

        "query: #{ts_type(endpoint[:query])} & PaginationQuery"
      end

      def call_args(endpoint)
        path = endpoint[:path].gsub(/[:*](\w+)/) { "${segment(#{camel(::Regexp.last_match(1))})}" }
        path = path.include?("${") ? "`#{path}`" : path.inspect
        options = endpoint[:query] || endpoint[:paginated] ? "{ ...options, query }" : "options"
        case client_verb(endpoint[:verb])
        when "get", "delete" then "#{path}, #{options}"
        else "#{path}, #{endpoint[:body] ? "data" : "undefined"}, #{options}"
        end
      end

      def client_verb(verb) = { "HEAD" => "get", "OPTIONS" => "get" }.fetch(verb, verb.downcase)

      def collect_refs(ref, refs)
        return unless ref

        refs << ref[:ref] if ref[:ref]
        refs << "Paginated" if ref[:page]
        collect_refs(ref[:array], refs) if ref[:array]
        collect_refs(ref[:page], refs) if ref[:page]
      end

      def index_file
        exports = @contract[:resources].map { |r| %(export { #{export_name(r)} } from "./#{file_base(r)}";) }
        "#{header}\nexport type * from \"./types\";\n#{exports.join("\n")}\n"
      end

      def file_base(resource) = resource[:name].tr("/", "_")
      def export_name(resource) = camel(resource[:name].tr("/", "_"))

      def camel(name)
        camel = Inflector.camelize(name)
        camel[0].downcase + camel[1..]
      end
    end
  end
end
