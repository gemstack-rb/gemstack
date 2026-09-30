# frozen_string_literal: true

# POST /api/auth/signup
class RegistrationsController < ApplicationController
  rate_limit to: 10, within: 3600, only: :create

  accepts :create do
    required :email, :string, max_length: 254
    required :password, :string, max_length: 1024
  end
  returns :create, UserSerializer

  def create
    user = User.create(email: input[:email], password: input[:password]) # invalid: 422 with field errors
    AuthMailer.email_verification(user.id).deliver_later
    sign_in(user)
    render user, status: :created
  end
end
