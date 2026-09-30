# frozen_string_literal: true

require "test_helper"

class AccountMailer < GemStack::Mailer
  default from: "Shop <hello@shop.test>"

  def welcome(name, email)
    @name = name
    mail to: email, subject: "Welcome, #{name}!"
  end

  def inline(email) = mail(to: email, subject: "Inline", text: "plain body")
  def forgetful(_email) = nil

  private

  def helper = "not an action"
end

class MailTest < Minitest::Test
  include GemStack::Mail::Testing

  def setup
    @delivery = GemStack.config.mail.delivery
    @root = Dir.mktmpdir
    GemStack.config.root = @root
    dir = File.join(@root, "app/mailers/templates/account_mailer")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "welcome.text.erb"), "Hi <%= @name %>!\n")
    File.write(File.join(dir, "welcome.html.erb"), "<p>Hi <%= @name %>!</p><%== '<b>ok</b>' %>")
  end

  def teardown
    GemStack.config.mail.delivery = @delivery
    FileUtils.rm_rf(@root)
  end

  def test_actions_and_delivery_objects
    assert_equal %w[forgetful inline welcome], AccountMailer.actions.sort
    assert_respond_to AccountMailer, :welcome
    refute_respond_to AccountMailer, :helper
    assert_instance_of GemStack::Mailer::Delivery, AccountMailer.welcome("Ada", "ada@example.com")
  end

  def test_renders_templates_with_html_escaping
    assert_emails(1) { AccountMailer.welcome("<Ada>", "ada@example.com").deliver_now }
    mail = last_email

    assert_equal ["ada@example.com"], mail.to
    assert_equal ["hello@shop.test"], mail.from
    assert_equal "Welcome, <Ada>!", mail.subject
    assert_equal "Hi <Ada>!\n", mail.text_part.decoded
    assert_equal "<p>Hi &lt;Ada&gt;!</p><b>ok</b>", mail.html_part.decoded
  end

  def test_inline_bodies_and_default_from
    AccountMailer.inline("x@example.com").deliver_now

    assert_equal "plain body", last_email.text_part.decoded
    assert_nil last_email.html_part
  end

  def test_actions_may_skip_sending
    assert_emails(0) { assert_nil AccountMailer.forgetful("x@example.com").deliver_now }
  end

  def test_missing_body
    klass = Class.new(GemStack::Mailer) { def empty = mail(to: "a@b.c", subject: "x") }
    Object.const_set(:EmptyMailer, klass)
    error = assert_raises(GemStack::Error) { EmptyMailer.empty.deliver_now }
    assert_includes error.message, "no body"
  ensure
    Object.send(:remove_const, :EmptyMailer)
  end

  def test_log_delivery_saves_a_preview
    GemStack.config.mail.delivery = :log
    AccountMailer.welcome("Ada", "ada@example.com").deliver_now
    files = Dir[File.join(@root, "tmp/mail/*")].map { |f| File.extname(f) }.sort

    assert_equal %w[.eml .html], files
    assert_empty deliveries
  end

  def test_custom_delivery_object
    sent = []
    GemStack.config.mail.delivery = Object.new.tap { |o| o.define_singleton_method(:deliver) { |m| sent << m } }
    AccountMailer.inline("x@example.com").deliver_now

    assert_equal ["x@example.com"], sent.first.to
  end

  def test_smtp_settings_from_url
    settings = GemStack::Mail.smtp_settings("smtp://user%40x.com:p%40ss@smtp.example.com:2525")

    assert_equal({ address: "smtp.example.com", port: 2525, user_name: "user@x.com", password: "p@ss",
                   authentication: :plain, tls: false, enable_starttls_auto: true, open_timeout: 5,
                   read_timeout: 10 }, settings)
    assert GemStack::Mail.smtp_settings("smtps://smtp.example.com")[:tls]
    assert_equal 465, GemStack::Mail.smtp_settings("smtps://smtp.example.com")[:port]
    assert_raises(GemStack::ConfigurationError) { GemStack::Mail.smtp_settings(nil) }
  end
end
