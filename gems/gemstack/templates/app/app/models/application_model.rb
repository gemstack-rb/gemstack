# frozen_string_literal: true

# The base class for this app's models — add plugins, validations and helpers
# every model should share here. `class Product < ApplicationModel` maps to the
# products table (docs/models.md).
#
# Created with Class.new on purpose: `class ApplicationModel < GemStack::Model`
# would make Sequel look for an "application_models" table.
ApplicationModel = Class.new(GemStack::Model) # rubocop:disable Style/EmptyClassDefinition

class ApplicationModel
  # Sequel plugins for every model, e.g.:
  # plugin :dirty                                    # previous values after an update (column_changes)

  # Shared query helpers:
  # dataset_module do
  #   def recent = order(Sequel.desc(:created_at))
  # end
end
