# frozen_string_literal: true

require "ripper"

module GemStack
  class CLI < Thor
    # Read the generated schema as syntax, never by executing a migration.
    # Customized or subsequently altered schemas require manual comparison.
    class MigrationChanges
      COLUMN_METHODS = %w[primary_key String Integer Bignum Float BigDecimal Date column foreign_key TrueClass].freeze

      def initialize(generator, root:, output:)
        @generator = generator
        @spec = generator.spec
        @root = root
        @output = output
      end

      def report(paths)
        schema = schema_from(paths)
        return manual_review unless schema

        columns, indexes = schema
        @spec.fields.each do |field|
          if !columns.key?(field.column)
            @output.puts("New column #{field.column}: gemstack g migration " \
                         "Add#{Inflector.camelize(field.name)}To#{@spec.plural_class} #{field_argument(field)}")
          elsif columns[field.column] != declaration(@generator.migration_column(field)) ||
                indexes.include?(field.column) != (field.index && !field.unique)
            @output.puts("Changed column #{field.column} (#{field_argument(field)}): gemstack g migration " \
                         "Change#{Inflector.camelize(field.name)}On#{@spec.plural_class}")
            @output.puts("  Edit its empty change block to alter the existing column, constraints or indexes " \
                         "on :#{@spec.table}; do not add the column again.")
          end
        end
        @output.puts("Review schema changes and backfill required columns before gemstack db:migrate.")
      end

      private

      def schema_from(paths)
        return unless paths.one?
        return if subsequent_changes?(paths.first)

        create_table_body(File.read(paths.first, encoding: "UTF-8"))
      end

      def create_table_body(source)
        statements = Ripper.sexp(source)&.fetch(1)
        return unless statements&.one?

        migration = body(statements.first)
        return unless canonical(statements.first[1]) == canonical(Ripper.sexp("Sequel.migration")[1][0])
        return unless migration&.one? && call(migration.first[1]) == ["change", []]

        changes = body(migration.first)
        return unless changes&.one? && call(changes.first[1]) == ["create_table", [symbol(@spec.table)]]

        parse_columns(body(changes.first))
      end

      def subsequent_changes?(path)
        Dir.glob(File.join(@root, "db/migrations/*.rb")).any? do |other|
          other > path && File.read(other, encoding: "UTF-8").match?(/\b#{Regexp.escape(@spec.table)}\b/)
        end
      end

      def body(node)
        return unless node&.first == :method_add_block

        block = node[2]
        return unless block[0] == :do_block && block[1].nil?

        statements = block[2]
        statements[1] if statements[0] == :bodystmt && statements.drop(2).all?(&:nil?)
      end

      def parse_columns(statements)
        return unless statements

        columns = {}
        indexes = []
        statements.each do |node|
          next if node == [:void_stmt]

          name, args = call(node)
          column = args&.first
          return nil unless column&.dig(0) == :symbol_literal

          column_name = column.dig(1, 1, 1)
          if name == "index" && args.one?
            indexes << column_name
          elsif COLUMN_METHODS.include?(name) && !columns.key?(column_name)
            columns[column_name] = [name, args]
          else
            return nil
          end
        end
        [columns, indexes]
      end

      def declaration(source) = call(Ripper.sexp(source)[1][0])
      def symbol(name) = canonical(Ripper.sexp(":#{name}")[1][0])

      def call(node)
        return unless node.is_a?(Array)

        case node[0]
        when :command
          name = node[1][1]
          arguments = node[2]
        when :method_add_arg
          return unless node[1][0] == :fcall

          name = node[1][1][1]
          arguments = node[2]
          arguments = arguments[1] if arguments[0] == :arg_paren
        else return
        end
        return [name, []] if arguments.nil? || arguments.empty?
        return unless arguments[0] == :args_add_block && arguments[2] == false

        [name, canonical(arguments[1])]
      end

      def canonical(node)
        return node unless node.is_a?(Array)
        return node.first(2) if node[0].is_a?(Symbol) && node[0].to_s.start_with?("@")

        normalized = node.map { |part| canonical(part) }
        normalized[1] = normalized[1].sort_by(&:inspect) if normalized[0] == :bare_assoc_hash
        normalized
      end

      def field_argument(field)
        [field.name, field.type, ("optional" if field.optional), ("unique" if field.unique),
         ("index" if field.index && !field.reference?)].compact.join(":")
      end

      def manual_review
        @output.puts("Cannot safely compare the retained migration with the requested fields " \
                     "(custom schema or later migrations). Review the current :#{@spec.table} schema.")
        @output.puts("Create a migration with gemstack g migration Update#{@spec.plural_class}Schema " \
                     "and edit its empty change block before gemstack db:migrate.")
      end
    end
  end
end
