# frozen_string_literal: true

require "gemstack/mail"

module GemStack
  module Mail
    # Test helpers (included into GemStack::TestCase by `gemstack add auth`):
    #
    #   assert_emails(1) { post_json "/api/auth/password/forgot", { email: user.email } }
    #   assert_equal [user.email], last_email.to
    module Testing
      def before_setup
        super
        Mail.deliveries.clear
      end

      def deliveries = Mail.deliveries
      def last_email = Mail.deliveries.last

      def assert_emails(count, &block)
        before = Mail.deliveries.size
        adapter = defined?(GemStack::Jobs) && GemStack::Jobs.adapter
        adapter = nil unless adapter.respond_to?(:perform_enqueued)
        queued = adapter ? adapter.enqueued.map { |job| job["id"] } : []
        block&.call
        # deliver_later mail sent inside the block counts too.
        adapter&.perform_enqueued(only: ["GemStack::Mail::DeliveryJob"], except_ids: queued)
        assert_equal count, Mail.deliveries.size - before,
                     "Expected #{count} email(s), got #{Mail.deliveries.size - before}"
      end
    end
  end
end
