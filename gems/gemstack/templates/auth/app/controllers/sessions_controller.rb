# frozen_string_literal: true

# POST /api/auth/login · GET /api/auth/me · DELETE /api/auth/logout
class SessionsController < ApplicationController
  before :require_login, only: :show
  # Per IP, and per account so one address can't be guessed at from many IPs.
  rate_limit to: 20, within: 300, only: :create
  rate_limit to: 10, within: 300, only: :create, name: "login-email", by: -> { params[:email].to_s.downcase }

  accepts :create do
    required :email, :string, max_length: 254
    required :password, :string, max_length: 1024
  end
  returns :create, UserSerializer
  returns :show, UserSerializer

  def create
    user = User.authenticate_by(email: input[:email], password: input[:password])
    # The same answer for "no such account" and "wrong password".
    raise GemStack::Unauthorized.new("Invalid email or password.", code: "invalid_credentials") unless user

    sign_in(user)
    render user
  end

  def show = render(current_user)

  def destroy = sign_out
end
