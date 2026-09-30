# frozen_string_literal: true

module GemStack
  # A small DSL for declaring configuration with defaults.
  #
  #   class HTTPConfig < GemStack::Settings
  #     setting :api_path, default: "/api"
  #     setting :health_path, default: -> { "#{api_path}/health" }
  #     namespace :cors do
  #       setting :origins, default: []
  #     end
  #   end
  #
  # - A callable default is evaluated lazily, in the context of the settings
  #   object, the first time it is read, and then memoized. This lets defaults
  #   depend on ENV or on other settings.
  # - Array/Hash defaults are duplicated per instance, so instances never share
  #   mutable state.
  # - Reading or writing an undeclared setting raises NoMethodError (with
  #   Ruby's did_you_mean suggestions), so typos fail fast.
  class Settings
    class << self
      def definitions
        @definitions ||= superclass <= Settings ? superclass.definitions.dup : {}
      end

      def namespaces
        @namespaces ||= superclass <= Settings ? superclass.namespaces.dup : {}
      end

      def setting(name, default: nil)
        name = name.to_sym
        definitions[name] = default
        define_method(name) { read(name) }
        define_method(:"#{name}=") { |value| @values[name] = value }
        name
      end

      # Declares a nested settings group. Pass a Settings subclass, or a block
      # that is evaluated in a new anonymous subclass. Modules use this to add
      # their own namespace to GemStack::Config without core knowing about them.
      def namespace(name, klass = nil, &)
        name = name.to_sym
        klass ||= Class.new(Settings, &)
        namespaces[name] = klass
        define_method(name) do |&configure|
          group = (@groups[name] ||= klass.new)
          configure&.call(group)
          group
        end
        klass
      end
    end

    def initialize
      @values = {}
      @groups = {}
    end

    def read(name)
      return @values[name] if @values.key?(name)

      default = self.class.definitions.fetch(name)
      @values[name] =
        case default
        when Proc then instance_exec(&default)
        when Array, Hash then default.dup
        else default
        end
    end

    def set?(name)
      @values.key?(name.to_sym)
    end

    def settings
      self.class.definitions.keys
    end

    def to_h
      hash = settings.to_h { |name| [name, read(name)] }
      self.class.namespaces.each_key { |name| hash[name] = public_send(name).to_h }
      hash
    end
  end
end
