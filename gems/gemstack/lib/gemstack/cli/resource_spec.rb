# frozen_string_literal: true

module GemStack
  class CLI < Thor
    # Everything the model/migration/resource generators need to know about a
    # resource, parsed once from the command line (ARCHITECTURE §7):
    #
    #   gemstack generate resource Product name:string price:decimal description:text:optional \
    #                                      sku:string:unique category:references active:boolean \
    #                                      status:enum:draft,published,archived
    #
    # Field syntax: name:type[:modifier...]; enums list their values first
    # (name:enum:a,b,c[:modifier...]). Fields are required (NOT NULL) unless
    # marked :optional. Booleans default to false, enums to their first value.
    # Modifiers: optional, unique, index.
    class ResourceSpec
      TYPES = %w[string text integer bigint float decimal boolean date datetime uuid json references enum].freeze
      MODIFIERS = %w[optional unique index].freeze
      REST_ACTIONS = %w[index show create update destroy].freeze

      Field = Struct.new(:name, :type, :optional, :unique, :index, :enum_values, keyword_init: true) do
        # Booleans and enums are NOT NULL too, but with a default: nothing to require.
        def required? = !optional && !%w[boolean enum].include?(type)
        def enum? = type == "enum"
        def default_value = enum? && !optional ? enum_values.first : nil
        def reference? = type == "references"
        def column = reference? ? "#{name}_id" : name
        def label = Inflector.humanize(name)
        def referenced_class = Inflector.camelize(name)
        def referenced_table = Inflector.pluralize(name)
        def model_type = reference? ? "references" : type
      end

      attr_reader :name, :fields, :actions

      def initialize(name, field_args = [], actions: REST_ACTIONS)
        @name = Inflector.camelize(Inflector.singularize(name.to_s.delete_suffix("Controller")))
        unless @name.match?(/\A[A-Z][A-Za-z0-9]*\z/)
          raise Thor::Error,
                "Invalid resource name #{name.inspect}: use a single CamelCase or snake_case name (e.g. Product)"
        end

        Generator.check_constant!(@name, suggestion: "#{@name}Record") unless @name == "Migration"
        @fields = field_args.map { |arg| parse_field(arg) }
        duplicates = @fields.group_by(&:column).select { |_, list| list.size > 1 }.keys
        raise Thor::Error, "Duplicate field(s): #{duplicates.join(", ")}" unless duplicates.empty?

        @actions = actions.map(&:to_s)
        invalid = @actions - REST_ACTIONS
        return if invalid.empty?

        raise Thor::Error,
              "Unknown action(s) #{invalid.join(", ")}; resources support #{REST_ACTIONS.join(", ")}"
      end

      # Product / LineItem examples:
      #   class_name Product · file_name product · plural products · plural_class Products
      #   url_segment line-items · client_name lineItems · variable lineItem · human "Line item"
      def class_name = name
      def file_name = Inflector.underscore(name)
      def plural = Inflector.pluralize(file_name)
      def table = plural
      def plural_class = Inflector.camelize(plural)
      def url_segment = Inflector.dasherize(plural)
      def client_name = lower_camel(plural)
      def variable = lower_camel(file_name)
      def human = Inflector.humanize(file_name)
      def human_plural = Inflector.humanize(plural)

      def action?(action) = actions.include?(action.to_s)
      def crud? = actions.sort == REST_ACTIONS.sort
      def references = fields.select(&:reference?)

      private

      def parse_field(arg)
        name, type, *mods = arg.to_s.split(":")
        type ||= "string"
        type = "references" if type == "belongs_to"
        raise Thor::Error, "Invalid field name in #{arg.inspect}" unless name&.match?(/\A[a-z][a-z0-9_]*\z/)
        unless TYPES.include?(type)
          raise Thor::Error,
                "Unknown type #{type.inspect} in #{arg.inspect}; types: #{TYPES.join(", ")}"
        end

        enum_values = parse_enum_values(arg, mods) if type == "enum"
        unknown = mods - MODIFIERS
        raise Thor::Error, "Unknown modifier(s) #{unknown.join(", ")} in #{arg.inspect}" unless unknown.empty?

        name = name.delete_suffix("_id") if type == "references"
        Field.new(name: name, type: type, optional: mods.include?("optional"), unique: mods.include?("unique"),
                  index: mods.include?("index") || type == "references", enum_values: enum_values)
      end

      # status:enum:draft,published → ["draft", "published"] (taken off mods).
      def parse_enum_values(arg, mods)
        values = mods.shift.to_s.split(",").map(&:strip)
        if values.empty? || values.any? { |value| !value.match?(/\A[a-z][a-z0-9_]*\z/) } || values.uniq != values
          raise Thor::Error, "Give an enum's values in #{arg.inspect}, e.g. status:enum:draft,published " \
                             "(lowercase letters, digits and _, no duplicates)"
        end

        values
      end

      def lower_camel(term)
        camel = Inflector.camelize(term)
        camel[0].downcase + camel[1..]
      end
    end
  end
end
