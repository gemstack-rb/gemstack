# frozen_string_literal: true

# Account emails. Templates: app/mailers/templates/auth_mailer/*.erb.
# Links point at the Next.js pages (config.auth.app_url, APP_URL in production).
class AuthMailer < ApplicationMailer
  def password_reset(user_id)
    @user = User[user_id] or return
    token, = GemStack::Auth::Tokens.issue(@user.id, purpose: "password_reset")
    @url = GemStack::Auth.url("/reset-password", token: token)
    @minutes = GemStack.config.auth.password_reset_ttl / 60
    mail to: @user.email, subject: "Reset your password"
  end

  def email_verification(user_id)
    @user = User[user_id] or return
    token, = GemStack::Auth::Tokens.issue(@user.id, purpose: "email_verification", email: @user.email)
    @url = GemStack::Auth.url("/verify-email", token: token)
    mail to: @user.email, subject: "Confirm your email address"
  end
end
