# frozen_string_literal: true

module GemStack
  class CLI < Thor
    # `gemstack generate migration NAME [fields]`
    #
    #   AddSkuToProducts sku:string:unique   → alter_table(:products) { add_column ... }
    #   anything else                        → an empty `change` block
    class MigrationGenerator < Generator
      attr_reader :file_name, :table, :columns, :timestamp

      def initialize(name, field_args, root:, output: $stdout, timestamp: nil)
        super(output: output)
        @root = root
        @file_name = Inflector.underscore(name.to_s)
        raise Thor::Error, "Invalid migration name #{name.inspect}" unless @file_name.match?(/\A[a-z][a-z0-9_]*\z/)

        @timestamp = timestamp || Generator.migration_timestamp(root)
        @table = @file_name[/\Aadd_\w+_to_(\w+)\z/, 1]
        spec = ResourceSpec.new("Migration", field_args)
        builder = ResourceGenerator.new(spec, root: root, output: output)
        @columns = spec.fields.flat_map do |field|
          [normalize(builder.migration_column(field),
                     field)] + (field.index && !field.unique ? ["add_index :#{field.column}"] : [])
        end
      end

      def run
        @manifest = GenerationManifest.new(@root)
        template_files("migration", override_root: @root).each do |rel, source|
          path = rel.delete_suffix(".tt").gsub("%timestamp%", timestamp).gsub("%file_name%", file_name)
          write_tracked(File.join(@root, path), render(File.read(source), source), owner: "migration:#{file_name}")
        end
        self
      ensure
        @manifest&.save
      end

      private

      # Turns a create_table column line into its alter_table equivalent.
      def normalize(line, field)
        if field.reference?
          line.sub(/\Aforeign_key/, "add_foreign_key")
        elsif line.start_with?("column ")
          line.sub(/\Acolumn :(\w+), /, 'add_column :\1, ')
        else
          type, rest = line.split(" ", 2)
          name, options = rest.split(",", 2)
          "add_column #{name}, #{type}#{",#{options}" if options}"
        end
      end
    end
  end
end
