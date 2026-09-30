# frozen_string_literal: true

require "test_helper"
require "gemstack/jobs"
require "gemstack/jobs/testing"

class LaterMailer < GemStack::Mailer
  def note(email, text) = mail(to: email, subject: "Note", text: text)
end

class DeliverLaterTest < Minitest::Test
  include GemStack::Jobs::Testing
  include GemStack::Mail::Testing

  def test_enqueues_a_delivery_job_on_the_mailers_queue
    LaterMailer.note("a@example.com", "hi").deliver_later

    assert_enqueued GemStack::Mail::DeliveryJob, args: ["LaterMailer", "note", ["a@example.com", "hi"]], queue: "mailers"
    assert_empty deliveries
  end

  def test_assert_emails_performs_delivery_jobs
    assert_emails(1) { LaterMailer.note("a@example.com", "hi").deliver_later(wait: 60) }
    assert_equal "hi", last_email.text_part.decoded
  end

  def test_rejects_non_mailers
    LaterMailer.note("a@example.com", "hi") # warm
    GemStack::Mail::DeliveryJob.perform_later("String", "new", [])

    assert_raises(ArgumentError) { perform_enqueued_jobs }
  end
end
