# frozen_string_literal: true

module GemStack
  class CLI < Thor
    # `gemstack generate policy Order` → app/policies/order_policy.rb + test.
    class PolicyGenerator < Generator
      attr_reader :model_name, :class_name, :file_name

      def initialize(name, root:, output: $stdout, force: false)
        super(output: output, force: force)
        @root = root
        @model_name = Inflector.camelize(name.to_s.delete_suffix("Policy").delete_suffix("_policy"))
        unless @model_name.match?(/\A[A-Z][A-Za-z0-9]*(::[A-Z][A-Za-z0-9]*)*\z/)
          raise Thor::Error,
                "Invalid policy name #{name.inspect}"
        end

        @class_name = "#{@model_name}Policy"
        @file_name = Inflector.underscore(@model_name)
      end

      def parent_class
        File.file?(File.join(@root, "app/policies/application_policy.rb")) ? "ApplicationPolicy" : "GemStack::Policy"
      end

      def run
        @manifest = GenerationManifest.new(@root)
        template_files("policy", override_root: @root).each do |rel, source|
          target = File.join(@root, rel.delete_suffix(".tt").gsub("%file_name%", file_name))
          write_tracked(target, render(File.read(source), source), owner: "policy:#{file_name}")
        end
        self
      ensure
        @manifest&.save
      end
    end
  end
end
