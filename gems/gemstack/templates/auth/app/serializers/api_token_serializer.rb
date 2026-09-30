# frozen_string_literal: true

class ApiTokenSerializer < ApplicationSerializer
  model AuthToken
  attributes :id, :name, :last_used_at, :expires_at, :created_at
end
