# frozen_string_literal: true

module GemStack
  module DB
    # Gives Sequel errors their HTTP meaning via GemStack::ErrorMapping (no
    # dependency on the HTTP layer), for PostgreSQL, MySQL and SQLite:
    #
    #   record not found           → 404 not_found
    #   model validation failed    → 422 validation_failed + field errors
    #   unique / not-null / FK     → 422 with the offending column when the database names it
    #   row still referenced (FK)  → 409 conflict
    #   database unreachable       → 503 service_unavailable
    module Errors
      KEY_DETAIL = /Key \(([^)]+)\)=/ # PostgreSQL
      MYSQL_KEY = /Duplicate entry .* for key '(?:[^.']+\.)?([^']+)'/   # MySQL 8 names table.index
      SQLITE_COLUMNS = /constraint failed: ((?:[\w.]+(?:, )?)+)/i       # UNIQUE / NOT NULL
      FK_COLUMN = /FOREIGN KEY \(`?([^`)]+)`?\)/                        # MySQL

      module_function

      def install!
        # Registered first: the specific classes below take precedence.
        ErrorMapping.register(Sequel::DatabaseError) { |error| mysql_missing_value(error) }
        install_record_errors!
        install_constraint_errors!
        ErrorMapping.register(Sequel::DatabaseConnectionError) { ServiceUnavailable.new("Database unavailable") }
        ErrorMapping.register(Sequel::PoolTimeout) { ServiceUnavailable.new("Database busy, try again") }
      end

      def install_record_errors!
        ErrorMapping.register(Sequel::NoMatchingRow) do |error|
          model = error.respond_to?(:dataset) && error.dataset.respond_to?(:model) ? error.dataset.model : nil
          RecordNotFound.new(model&.name ? "#{model.name} not found" : "Record not found")
        end
        ErrorMapping.register(Sequel::ValidationFailed) do |error|
          ValidationError.new(errors: stringify(error.errors))
        end
        ErrorMapping.register(Sequel::InvalidValue) do |error|
          ValidationError.new(error.message.sub(/\A.*?: /, "Invalid value: "), code: "invalid_value")
        end
        ErrorMapping.register(Sequel::MassAssignmentRestriction) do |error|
          BadRequest.new(error.message, code: "unknown_attribute")
        end
      end

      def install_constraint_errors!
        ErrorMapping.register(Sequel::UniqueConstraintViolation) do |error|
          field_error(columns(error), "is already taken") || Conflict.new("Record already exists")
        end
        ErrorMapping.register(Sequel::NotNullConstraintViolation) do |error|
          field_error([column(error)].compact, "is required") || ValidationError.new("A required value is missing")
        end
        ErrorMapping.register(Sequel::ForeignKeyConstraintViolation) do |error|
          if referenced_missing?(error)
            field_error(columns(error), "does not exist") || ValidationError.new("A referenced record does not exist")
          else
            Conflict.new("Record is still referenced by other records", code: "still_referenced")
          end
        end
        ErrorMapping.register(Sequel::CheckConstraintViolation) do
          ValidationError.new("A value violates a database constraint", code: "constraint_violation")
        end
      end

      # MySQL (strict mode) reports an omitted NOT NULL column without a
      # default as a plain error: "Field 'name' doesn't have a default value".
      def mysql_missing_value(error)
        name = error.message[/Field '([^']+)' doesn't have a default value/, 1]
        name && ValidationError.new(errors: { name => ["is required"] })
      end

      def stringify(errors) = errors.to_h { |key, messages| [Array(key).join(","), Array(messages)] }

      def field_error(names, message)
        return nil if names.empty?

        ValidationError.new(errors: names.to_h { |name| [name, [message]] })
      end

      def pg_error(error) = error.respond_to?(:wrapped_exception) ? error.wrapped_exception : nil

      # PostgreSQL: "is not present in table"; MySQL: "Cannot add or update a child row".
      # SQLite doesn't say which side failed, so it is reported as a conflict.
      def referenced_missing?(error)
        message = error.message
        message.include?("is not present") || message.include?("Cannot add or update a child row")
      end

      # The columns named by a unique or foreign-key violation, when the database says.
      def columns(error)
        message = error.message
        if (detail = pg_detail(error) || message[KEY_DETAIL]) && (match = KEY_DETAIL.match(detail))
          match[1].split(",").map(&:strip).map { |c| c.delete('"') }
        elsif (match = SQLITE_COLUMNS.match(message))
          match[1].split(", ").map { |name| name.split(".").last }
        elsif (match = FK_COLUMN.match(message))
          [match[1]]
        elsif (match = MYSQL_KEY.match(message))
          index_column(match[1])
        else
          []
        end
      rescue StandardError
        []
      end

      def column(error)
        message = error.message
        (defined?(PG::PG_DIAG_COLUMN_NAME) && pg_error(error)&.result&.error_field(PG::PG_DIAG_COLUMN_NAME)) ||
          message[/column "([^"]+)"/, 1] || message[/Column '([^']+)' cannot be null/, 1] ||
          sqlite_column(message)
      rescue StandardError
        nil
      end

      def sqlite_column(message)
        list = message[SQLITE_COLUMNS, 1] or return nil
        list.split(", ").first.split(".").last
      end

      def pg_detail(error)
        return nil unless defined?(PG::PG_DIAG_MESSAGE_DETAIL)

        pg_error(error)&.result&.error_field(PG::PG_DIAG_MESSAGE_DETAIL)
      end

      # MySQL reports the index, not the column. `unique: true` on a column
      # (what the generators write) names the index after the column; other
      # indexes (table_column_index, composite) can't be mapped to one field.
      def index_column(name)
        name == "PRIMARY" || name.match?(/_(?:key|unique|uniq|index)\z/) ? [] : [name]
      end
    end
  end
end

GemStack::DB::Errors.install!
