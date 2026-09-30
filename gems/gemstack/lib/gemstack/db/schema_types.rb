# frozen_string_literal: true

module GemStack
  module DB
    # Migrations may use PostgreSQL's type names — the generators write
    # `column :created_at, :timestamptz` — and still run on MySQL and SQLite,
    # where each maps to the closest native type. Everything
    # else in the Sequel schema DSL is untouched.
    module SchemaTypes
      MAPPINGS = {
        mysql: { "timestamptz" => "datetime(6)", "timestamp" => "datetime(6)", "jsonb" => "json",
                 "uuid" => "char(36)", "inet" => "varchar(45)", "citext" => "varchar(255)" },
        sqlite: { "timestamptz" => "timestamp", "jsonb" => "json", "uuid" => "varchar(36)",
                  "inet" => "varchar(45)", "citext" => "varchar(255)" }
      }.freeze

      private

      def type_literal_specific(column)
        type = column[:type]
        mapped = MAPPINGS.dig(database_type, type.to_s.downcase) if type.is_a?(Symbol) || type.is_a?(String)
        mapped || super
      end
    end
  end
end

Sequel::Database.prepend(GemStack::DB::SchemaTypes)
