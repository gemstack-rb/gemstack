# frozen_string_literal: true

# Accounts. GemStack::Auth::User adds password hashing (Argon2id), email
# normalization, validations and User.authenticate_by(email:, password:).
class User < ApplicationModel
  include GemStack::Auth::User

  field :email, :string, null: false, size: 254
  field :email_verified_at, :datetime

  has_many :auth_tokens
end
