# frozen_string_literal: true

module GemStack
  module DB
    # Sequel (5.108 and earlier) parses JSON/JSONB columns with
    # JSON.parse(json, create_additions: false), an option json 3.0 removed, so
    # every jsonb read raises ArgumentError. JSON.parse never creates additions,
    # so dropping the option keeps Sequel's behaviour.
    module JSONCompat
      def parse_json(json) = JSON.parse(json)

      def self.install!
        return unless Gem::Version.new(JSON::VERSION) >= Gem::Version.new("3.0")

        Sequel.singleton_class.prepend(self)
      end
    end
  end
end

GemStack::DB::JSONCompat.install!
