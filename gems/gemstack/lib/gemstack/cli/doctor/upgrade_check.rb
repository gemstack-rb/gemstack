# frozen_string_literal: true

module GemStack
  class CLI < Thor
    class Doctor
      # `gemstack doctor` for apps generated before 0.3.0, when every module
      # was its own gem: says exactly what to change to finish upgrading.
      module UpgradeCheck
        # Gems merged into gemstack in 0.3.0; their last release (0.3.0) only loads gemstack.
        RETIRED_GEMS = %w[core cache schema http db jobs mail storage contract dev].freeze
        LOADED_BY_REQUIRE = %w[db jobs mail storage].freeze

        # Apps generated before 0.3.0 list the retired gems in the Gemfile.
        def check_gemstack_upgrade
          gemfile = read("Gemfile").to_s
          retired = RETIRED_GEMS.select { |name| gemfile.match?(/^\s*gem "gemstack-#{name}"/) }
          return if retired.empty?

          app_rb = read("config/app.rb").to_s
          missing = (retired & LOADED_BY_REQUIRE).reject { |name| app_rb.include?(%(require "gemstack/#{name}")) }
          gems = retired.map { |name| %(gem "gemstack-#{name}") }
          requires = missing.map { |name| %(require "gemstack/#{name}") }
          steps = []
          steps << "remove #{gems.join(", ")} from the Gemfile" if gems.any?
          steps << "add #{requires.join(", ")} to config/app.rb" if requires.any?
          caution("set up for GemStack before 0.3",
                  "#{steps.join("; ")}, then bundle install (CHANGELOG: upgrading to 0.3)")
        end
      end
    end
  end
end
