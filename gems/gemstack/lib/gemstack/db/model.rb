# frozen_string_literal: true

module GemStack
  # Base class for models: Sequel::Model plus GemStack conventions.
  #
  #   class Product < GemStack::Model
  #     field :name, :string, null: false, size: 120
  #     field :price, :decimal, null: false, gt: 0
  #     field :active, :boolean, null: false, default: true
  #
  #     validates :name, format: /\A\S/
  #     belongs_to :category
  #     has_many :reviews
  #   end
  #
  # `field` declarations are metadata that drive validations, request
  # schemas (Product.input_schema), serializer types and TypeScript. The
  # database schema itself comes from migrations; everything Sequel offers
  # (datasets, associations, hooks, plugins) is available unchanged.
  #
  # Created with Class.new on purpose: an *anonymous* subclass stops Sequel
  # from binding GemStack::Model itself to a "models" table (which would need
  # a database connection just to require this file).
  Model = Class.new(Sequel::Model) # rubocop:disable Style/EmptyClassDefinition

  class Model
    Field = Struct.new(:name, :type, :options)

    FIELD_RULES = %i[null default size gt gte lt lte in format].freeze

    plugin :timestamps, update_on_create: true
    plugin :validation_helpers

    # A model may load before its migration has run (e.g. while generating the
    # API contract right after `generate resource`); queries still fail
    # clearly with "relation does not exist".
    self.require_valid_table = false

    class << self
      def gemstack_fields
        @gemstack_fields ||= superclass.respond_to?(:gemstack_fields) ? superclass.gemstack_fields.dup : {}
      end

      # Declares a field. Options: null: false (required), default:, size:
      # (max length), gt/gte/lt/lte, in:, format:. Types are GemStack::Types.
      def field(name, type, **options)
        Types.fetch(type)
        unknown = options.keys - FIELD_RULES
        raise ArgumentError, "unknown field option(s) #{unknown.inspect} for #{name}" unless unknown.empty?

        @input_schemas = nil
        serialize_json(name) if Types::CLASS_ALIASES.fetch(type, type).to_sym == :json
        gemstack_fields[name.to_sym] = Field.new(name.to_sym, Types::CLASS_ALIASES.fetch(type, type).to_sym,
                                                 options.freeze)
      end

      def gemstack_validations
        @gemstack_validations ||=
          superclass.respond_to?(:gemstack_validations) ? superclass.gemstack_validations.dup : []
      end

      # validates :name, :sku, presence: true, length: { max: 40 }, format: /\A[A-Z]/,
      #           inclusion: { in: %w[a b] }, numericality: { gt: 0 }, uniqueness: true
      def validates(*names, **rules)
        unknown = rules.keys - %i[presence length format inclusion numericality uniqueness]
        raise ArgumentError, "unknown validation(s) #{unknown.inspect}" unless unknown.empty?

        gemstack_validations << [names.map(&:to_sym), rules]
      end

      # A request schema derived from the field declarations (memoized):
      #   accepts :create, with: Product.input_schema
      def input_schema(only: nil, except: nil)
        key = [only, except]
        (@input_schemas ||= {})[key] ||= Schema.from_model(
          self, only: only, except: except, type_name: "#{name.to_s.split("::").join}Input"
        )
      end

      # find(42) raises GemStack::DB::RecordNotFound (404) when missing.
      # With a Hash or block it behaves like Sequel's find (nil when missing).
      def find(*args, &block)
        return super if block || args.size != 1 || args.first.is_a?(Hash)

        id = args.first
        record = valid_primary_key?(id) ? with_pk(id) : nil
        record || raise(DB::RecordNotFound, "#{name} #{id} not found")
      end

      def find_by(conditions) = first(conditions)
      def find_by!(conditions) = first(conditions) || raise(DB::RecordNotFound, "#{name} not found")

      alias create! create

      # Associations with familiar names; the Sequel names work too.
      def belongs_to(name, **) = many_to_one(name, **)
      def has_many(name, **) = one_to_many(name, **) # rubocop:disable Naming/PredicatePrefix
      def has_one(name, **) = one_to_one(name, **) # rubocop:disable Naming/PredicatePrefix
      def has_and_belongs_to_many(name, **) = many_to_many(name, **) # rubocop:disable Naming/PredicatePrefix

      private

      # PostgreSQL's jsonb comes back as Hash/Array (pg_json); MySQL JSON and
      # SQLite text come back as strings, so those fields are (de)serialized.
      def serialize_json(name)
        return if db.database_type == :postgres

        plugin :serialization unless respond_to?(:serialization_map)
        serialize_attributes :json, name unless serialization_map.key?(name.to_sym)
      end

      # For a table that doesn't exist yet, skip Sequel's schema queries: they
      # would fail and log two errors per model (e.g. while `gemstack contract`
      # runs before `db:migrate`). One cheap catalog lookup decides.
      def get_db_schema(reload = reload_db_schema?)
        return super unless missing_table?

        set_columns(nil)
        {}
      end

      def missing_table?
        return false unless @dataset

        DB.table_missing?(db, dataset.first_source_table)
      rescue Sequel::Error
        false
      end

      def valid_primary_key?(id)
        return true unless integer_primary_key?

        id.is_a?(Integer) || (id.is_a?(String) && id.match?(/\A\d{1,19}\z/))
      end

      def integer_primary_key?
        return @integer_primary_key if defined?(@integer_primary_key)

        @integer_primary_key = primary_key.is_a?(Symbol) && db_schema.dig(primary_key, :type) == :integer
      end
    end

    alias update! update

    # Identifies this version of the record, for ETags (Controller#stale?) and
    # cache keys: "product/42-1759052159.123456".
    def cache_key
      stamp = respond_to?(:updated_at) && updated_at ? "-#{updated_at.to_f}" : ""
      "#{Inflector.underscore(self.class.name.to_s)}/#{pk}#{stamp}"
    end

    def validate
      super
      validate_fields
      self.class.gemstack_validations.each { |names, rules| apply_validations(names, rules) }
    end

    # Models are never rendered implicitly: exposing every column is how
    # APIs leak data. Define a serializer instead.
    def as_json(*)
      file = "#{Inflector.underscore(self.class.name)}_serializer.rb"
      raise Error, "#{self.class.name} has no serializer. Create #{file} " \
                   "in app/serializers (class #{self.class.name}Serializer < GemStack::Serializer)."
    end

    def to_json(*) = as_json

    private

    def validate_fields
      self.class.gemstack_fields.each_value do |field|
        opts = field.options
        name = field.name
        if opts[:null] == false && !opts.key?(:default)
          if field.type == :boolean
            validates_includes([true, false], name, message: "must be true or false")
          else
            validates_presence(name, message: "is required")
          end
        end
        apply_rules(name, opts)
      end
    end

    def apply_rules(name, opts)
      if opts[:size].is_a?(Integer)
        validates_max_length(opts[:size], name, message: "is too long (maximum #{opts[:size]} characters)",
                                                allow_nil: true)
      end
      { gt: :>, gte: :>=, lt: :<, lte: :<= }.each do |key, operator|
        next unless opts.key?(key)

        words = { gt: "greater than", gte: "greater than or equal to", lt: "less than", lte: "less than or equal to" }
        validates_operator(operator, opts[key], name, message: "must be #{words[key]} #{opts[key]}", allow_nil: true)
      end
      if opts[:in]
        validates_includes(opts[:in], name, message: "must be one of: #{opts[:in].to_a.join(", ")}",
                                            allow_nil: true)
      end
      validates_format(opts[:format], name, message: "is invalid", allow_nil: true) if opts[:format]
    end

    def apply_validations(names, rules)
      names.each do |name|
        validates_presence(name, message: "is required") if rules[:presence]
        length = rules[:length]
        if length
          apply_rules(name, size: length[:max]) if length[:max]
          if length[:min]
            validates_min_length(length[:min], name, message: "is too short (minimum #{length[:min]} characters)",
                                                     allow_nil: true)
          end
        end
        apply_rules(name, format: rules[:format]) if rules[:format]
        inclusion = rules[:inclusion]
        apply_rules(name, in: inclusion.is_a?(Hash) ? inclusion[:in] : inclusion) if inclusion
        numeric = rules[:numericality]
        if numeric
          validates_numeric(name, message: "must be a number", allow_nil: true)
          apply_rules(name, numeric.slice(:gt, :gte, :lt, :lte)) if numeric.is_a?(Hash)
        end
        validates_unique(name, message: "is already taken") if rules[:uniqueness]
      end
    end
  end
end
