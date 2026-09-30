# frozen_string_literal: true

# What the API shows about the signed-in user. Never add password_digest.
class UserSerializer < ApplicationSerializer
  attributes :id, :email, :email_verified_at, :created_at
end
