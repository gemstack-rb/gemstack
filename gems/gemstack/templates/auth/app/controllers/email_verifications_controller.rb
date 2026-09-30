# frozen_string_literal: true

# POST /api/auth/email/resend · POST /api/auth/email/verify
class EmailVerificationsController < ApplicationController
  before :require_login, only: :create
  rate_limit to: 5, within: 3600, only: :create
  rate_limit to: 20, within: 3600, only: :update

  accepts :update do
    required :token, :string, max_length: 200
  end
  returns :create, nil
  returns :update, nil

  def create
    AuthMailer.email_verification(current_user.id).deliver_later unless current_user.email_verified?
    head :accepted
  end

  # Works signed in or out: the link may be opened on another device.
  def update
    row = GemStack::Auth::Tokens.consume(input[:token], purpose: "email_verification")
    user = row && User[row[:user_id]]
    # Only valid for the address it was sent to.
    unless user && user.email == row[:email]
      raise GemStack::BadRequest.new("This verification link is invalid or has expired.", code: "invalid_token")
    end

    user.update(email_verified_at: Time.now) unless user.email_verified?
  end
end
