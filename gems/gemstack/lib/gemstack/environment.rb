# frozen_string_literal: true

module GemStack
  # The running environment: development, test, production, or any custom name.
  #
  #   GemStack.env.production?  # => false
  #   GemStack.env.to_s         # => "development"
  class Environment
    KNOWN = %w[development test production].freeze

    attr_reader :name

    def self.detect(env = ENV)
      new(env["GEMSTACK_ENV"] || env["RACK_ENV"] || "development")
    end

    def initialize(name)
      @name = name.to_s.strip.downcase
      raise ArgumentError, "environment name cannot be empty" if @name.empty?
    end

    def development? = name == "development"
    def test? = name == "test"
    def production? = name == "production"

    # Anything that isn't development or test is treated like production for
    # safety-related defaults (hiding error details, JSON logs, ...).
    def local? = development? || test?

    def to_s = name
    def to_sym = name.to_sym
    def ==(other) = name == other.to_s
    alias eql? ==
    def hash = name.hash
    def inspect = "#<GemStack::Environment #{name}>"
  end
end
