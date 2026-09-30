# frozen_string_literal: true

# POST /api/auth/password/forgot · POST /api/auth/password/reset
class PasswordResetsController < ApplicationController
  rate_limit to: 10, within: 3600, only: :create
  rate_limit to: 3, within: 3600, only: :create, name: "reset-email", by: -> { params[:email].to_s.downcase }
  rate_limit to: 10, within: 3600, only: :update

  accepts :create do
    required :email, :string, max_length: 254
  end
  accepts :update do
    required :token, :string, max_length: 200
    required :password, :string, max_length: 1024
  end
  returns :create, nil
  returns :update, UserSerializer

  # Always 202: whether an account exists is nobody else's business.
  def create
    user = User.first(email: User.normalize_email(input[:email]))
    AuthMailer.password_reset(user.id).deliver_later if user
    head :accepted
  end

  def update
    errors = GemStack::Auth::Password.errors(input[:password])
    raise GemStack::ValidationError.new(errors: { password: errors }) unless errors.empty?

    row = GemStack::Auth::Tokens.consume(input[:token], purpose: "password_reset")
    raise GemStack::BadRequest.new("This reset link is invalid or has expired.", code: "invalid_token") unless row

    user = User[row[:user_id]]
    user.update(password: input[:password])
    # A reset usually means the old password leaked: end every session.
    GemStack::Auth::Sessions.revoke_all(user.id)
    sign_in(user)
    render user
  end
end
