# frozen_string_literal: true

require "mail"
require "erubi"
require "uri"
require "gemstack/core"

module GemStack
  # Email.
  #
  #   class AccountMailer < GemStack::Mailer
  #     default from: "Shop <hello@shop.test>"
  #
  #     def welcome(user_id)
  #       @user = User.find(user_id)
  #       mail to: @user.email, subject: "Welcome!" # templates/account_mailer/welcome.{text,html}.erb
  #     end
  #   end
  #
  #   AccountMailer.welcome(user.id).deliver_later   # through GemStack::Jobs (pass ids)
  #   AccountMailer.welcome(user.id).deliver_now
  module Mail
    class Config < Settings
      # :smtp (production), :log (development: logged and saved to tmp/mail),
      # :test (captured in GemStack::Mail.deliveries), or an object with #deliver(message).
      setting :delivery, default: lambda {
        if GemStack.env.test? then :test
        elsif GemStack.env.development? then :log
        else :smtp
        end
      }
      # smtp://user:password@smtp.example.com:587 (STARTTLS) or smtps://…:465
      setting :smtp_url, default: -> { ENV.fetch("SMTP_URL", nil) }
      setting :default_from, default: -> { ENV.fetch("MAIL_FROM", "#{GemStack.config.name} <no-reply@localhost>") }
      setting :templates_path, default: "app/mailers/templates"
      setting :preview_dir, default: "tmp/mail"
      # Queue used by deliver_later.
      setting :queue, default: "mailers"
    end

    class DeliveryError < Error; end

    # Loaded on first use, also by a jobs worker resolving the queued class name.
    autoload :DeliveryJob, "gemstack/mail/delivery_job"

    @deliveries = []
    @mutex = Mutex.new

    class << self
      def config = GemStack.config.mail

      # Messages delivered with the :test method.
      attr_reader :deliveries

      def deliver(message)
        method = config.delivery
        case method
        when :test, "test" then @mutex.synchronize { @deliveries << message }
        when :log, "log" then deliver_to_log(message)
        when :smtp, "smtp" then deliver_smtp(message)
        else
          unless method.respond_to?(:deliver)
            raise ConfigurationError,
                  "a mail delivery method must respond to #deliver"
          end

          method.deliver(message)
        end
        GemStack.logger.info("mail.delivered", to: Array(message.to).join(","), subject: message.subject,
                                               via: method.is_a?(Symbol) ? method : method.class.name)
        message
      end

      def smtp_settings(url = config.smtp_url)
        if url.to_s.empty?
          raise ConfigurationError,
                "set SMTP_URL (e.g. smtp://user:pass@smtp.example.com:587) to send mail"
        end

        uri = URI.parse(url)
        {
          address: uri.host, port: uri.port || (uri.scheme == "smtps" ? 465 : 587),
          user_name: uri.user && URI.decode_www_form_component(uri.user),
          password: uri.password && URI.decode_www_form_component(uri.password),
          authentication: uri.user ? :plain : nil, tls: uri.scheme == "smtps",
          enable_starttls_auto: uri.scheme != "smtps", open_timeout: 5, read_timeout: 10
        }.compact
      end

      private

      def deliver_smtp(message)
        message.delivery_method(:smtp, smtp_settings)
        message.deliver
      rescue Net::SMTPError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
        raise DeliveryError, "SMTP delivery failed: #{e.class}: #{e.message}"
      end

      # Development: a log line plus a copy on disk (.eml, and .html to open in a browser).
      def deliver_to_log(message)
        dir = File.expand_path(config.preview_dir, GemStack.config.root)
        FileUtils.mkdir_p(dir)
        slug = message.subject.to_s.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-")[0, 40]
        base = File.join(dir, "#{Time.now.strftime("%Y%m%d-%H%M%S-%L")}-#{slug}")
        File.write("#{base}.eml", message.to_s)
        html = message.html_part&.decoded
        File.write("#{base}.html", html) if html
        GemStack.logger.info("mail saved", to: Array(message.to).join(","), subject: message.subject,
                                           file: "#{base}#{".html" if html}")
      end
    end
  end

  # Base class for mailers. Public instance methods are mail "actions";
  # calling one on the class returns a Delivery. An action that returns
  # without calling `mail` sends nothing (e.g. the user was deleted since).
  class Mailer
    # Rendered as the value of @variables set in the action.
    class TemplateContext
      def initialize(mailer)
        mailer.instance_variables.each { |ivar| instance_variable_set(ivar, mailer.instance_variable_get(ivar)) }
      end

      def render(source, escape:) = instance_eval(Erubi::Engine.new(source, escape: escape).src)
    end

    # A message waiting to be delivered.
    class Delivery
      attr_reader :mailer_class, :action, :args

      def initialize(mailer_class, action, args)
        @mailer_class = mailer_class
        @action = action
        @args = args
      end

      def message
        return @message if defined?(@message)

        @message = mailer_class.new.build(action, args)
      end

      # nil when the action decided not to send (it returned without calling mail).
      def deliver_now
        msg = message
        msg && Mail.deliver(msg)
      end

      # Delivers from a background job (arguments must be JSON values — pass ids).
      def deliver_later(wait: nil)
        require "gemstack/jobs" # part of the gemstack gem; loaded here if config/app.rb doesn't
        job = wait ? Mail::DeliveryJob.set(wait: wait) : Mail::DeliveryJob
        job.perform_later(mailer_class.name, action.to_s, args)
      end
    end

    class << self
      def default(**headers) = defaults.merge!(headers.transform_keys(&:to_sym))
      def defaults = @defaults ||= superclass.respond_to?(:defaults) ? superclass.defaults.dup : {}

      def actions
        (public_instance_methods(true) - Mailer.public_instance_methods(true)).map(&:to_s)
      end

      def respond_to_missing?(name, include_private = false) = actions.include?(name.to_s) || super

      def method_missing(name, *args)
        return super unless actions.include?(name.to_s)

        Delivery.new(self, name.to_s, args)
      end
    end

    def build(action, args)
      @action = action
      public_send(action, *args)
      GemStack.logger.debug("mail skipped", mailer: self.class.name, action: action) unless @message
      @message
    end

    # Builds the message. Bodies come from text:/html: or, when omitted, from
    # templates: <templates_path>/<mailer>/<action>.text.erb and .html.erb
    # (HTML templates escape <%= %> output; use <%== %> for trusted markup).
    def mail(to:, subject:, text: nil, html: nil, from: nil, cc: nil, bcc: nil, reply_to: nil, template: @action)
      headers = self.class.defaults
      text ||= render_template(template, "text", escape: false)
      html ||= render_template(template, "html", escape: true)
      raise Error, "#{self.class.name}##{@action}: no body (give text:/html: or add a template)" unless text || html

      @message = build_message(to: to, subject: subject, text: text, html: html,
                               from: from || headers[:from] || Mail.config.default_from, cc: cc, bcc: bcc,
                               reply_to: reply_to || headers[:reply_to])
    end

    private

    def render_template(name, format, escape:)
      path = File.join(GemStack.config.root, Mail.config.templates_path, Inflector.underscore(self.class.name),
                       "#{name}.#{format}.erb")
      return nil unless File.file?(path)

      TemplateContext.new(self).render(File.read(path), escape: escape)
    end

    def build_message(to:, subject:, text:, html:, from:, cc:, bcc:, reply_to:)
      message = ::Mail.new
      message.from = from
      message.to = to
      message.cc = cc if cc
      message.bcc = bcc if bcc
      message.reply_to = reply_to if reply_to
      message.subject = subject
      if text
        message.text_part = ::Mail::Part.new do
          body text
          content_type "text/plain; charset=UTF-8"
        end
      end
      if html
        message.html_part = ::Mail::Part.new do
          body html
          content_type "text/html; charset=UTF-8"
        end
      end
      message
    end
  end
end

GemStack::Config.namespace(:mail, GemStack::Mail::Config)
