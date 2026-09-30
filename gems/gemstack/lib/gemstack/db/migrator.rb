# frozen_string_literal: true

Sequel.extension :migration

module GemStack
  module DB
    # Timestamped Sequel migrations in db/migrations:
    #
    #   # db/migrations/20260928120000_create_products.rb
    #   Sequel.migration do
    #     change do
    #       create_table(:products) do
    #         primary_key :id, type: :Bignum
    #         String :name, null: false
    #         timestamptz :created_at, null: false
    #       end
    #     end
    #   end
    #
    # Migrations are plain Sequel migrations; the full Sequel schema DSL applies.
    class Migrator
      Entry = Struct.new(:version, :name, :file, :applied, keyword_init: true)

      attr_reader :db, :path

      def initialize(database = DB.connection, path = GemStack.root.join(DB.config.migrations_path).to_s)
        @db = database
        @path = path.to_s
      end

      def files = Dir.glob(File.join(path, "*.rb"))

      # Applies pending migrations (or migrates up/down to target). Returns the
      # file names that were applied or reverted.
      def migrate(target: nil)
        before = applied
        run(target)
        after = applied
        (after - before) + (before - after)
      end

      # Reverts the last `steps` applied migrations.
      def rollback(steps: 1)
        versions = applied.map { |file| version_of(file) }.sort
        return [] if versions.empty?

        target = versions[-(steps + 1)] || 0
        migrate(target: target)
      end

      def status
        done = applied
        files.map do |file|
          base = File.basename(file)
          Entry.new(version: version_of(base), name: base.sub(/\A\d+_/, "").delete_suffix(".rb"), file: base,
                    applied: done.include?(base))
        end.sort_by(&:version)
      end

      def pending = status.reject(&:applied)
      def pending? = !pending.empty?

      def applied
        return [] if DB.table_missing?(db, :schema_migrations)

        db[:schema_migrations].select_map(:filename)
      end

      private

      def run(target)
        return unless File.directory?(path)

        Sequel::TimestampMigrator.new(db, path, target: target).run
      end

      def version_of(file) = File.basename(file)[/\A\d+/].to_i
    end
  end
end
