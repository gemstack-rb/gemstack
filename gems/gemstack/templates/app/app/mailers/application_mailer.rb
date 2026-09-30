# frozen_string_literal: true

# The base class for this app's mailers (docs/mail.md). Templates live in
# app/mailers/templates/<mailer>/<action>.{text,html}.erb.
class ApplicationMailer < GemStack::Mailer
  # default from: "My App <hello@example.com>"          # otherwise config.mail.default_from (MAIL_FROM)
  # default reply_to: "support@example.com"
end
