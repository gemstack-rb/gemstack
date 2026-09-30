# frozen_string_literal: true

require "gemstack/jobs"

module GemStack
  module Mail
    # Delivers a mailer action in the background (Delivery#deliver_later).
    # Retried like any job; SMTP errors are transient more often than not.
    class DeliveryJob < GemStack::Job
      def self.queue(name = nil) = name ? super : (@queue || Mail.config.queue)

      def perform(mailer_name, action, args)
        mailer = Object.const_get(mailer_name)
        raise ArgumentError, "#{mailer_name} is not a GemStack::Mailer" unless mailer.is_a?(Class) && mailer < Mailer

        Mailer::Delivery.new(mailer, action, args).deliver_now
      end
    end
  end
end
