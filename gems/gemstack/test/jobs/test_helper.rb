# frozen_string_literal: true

ENV["GEMSTACK_ENV"] = "test"
require "gemstack/jobs"
require "gemstack/jobs/testing"
require "minitest/autorun"
require "stringio"
require "timeout"

GemStack.config.logger.output = nil

# Jobs used across the tests. They record what happened in RECORD.
RECORD = Queue.new

class RecordingJob < GemStack::Job
  queue :recording
  def perform(*args) = RECORD << [:performed, args, attempt]
end

class FlakyJob < GemStack::Job
  retry_on RuntimeError, attempts: 3, wait: 0
  def perform(key) = attempt < 2 ? raise("flaky #{key}") : RECORD << [:recovered, key, attempt]
end

class AlwaysFailingJob < GemStack::Job
  retry_on StandardError, attempts: 2, wait: 0
  def perform = raise(ArgumentError, "broken")
end

class DiscardingJob < GemStack::Job
  discard_on GemStack::NotFound
  def perform = raise(GemStack::NotFound, "gone")
end

class EnqueuingJob < GemStack::Job
  def perform(remaining) = remaining.positive? ? EnqueuingJob.perform_later(remaining - 1) : RECORD << [:done]
end

def drain_record
  items = []
  items << RECORD.pop until RECORD.empty?
  items
end

# Database-queue tests need GEMSTACK_TEST_DATABASE_URL (PostgreSQL, MySQL or SQLite).
module JobsDB
  URL = ENV.fetch("GEMSTACK_TEST_DATABASE_URL", nil)

  def self.db
    return @db if defined?(@db)

    @db = URL && begin
      require "gemstack/db"
      GemStack.config.db.url = URL
      GemStack::DB::Tasks.create
      db = GemStack::DB.connection
      db.drop_table?(:gemstack_jobs)
      GemStack::Jobs::Migration.apply(db)
      db
    rescue Sequel::Error => e
      warn "database unavailable (#{e.message.lines.first.strip}); skipping queue tests"
      nil
    end
  end

  def setup
    skip "set GEMSTACK_TEST_DATABASE_URL to run the database queue tests" unless JobsDB.db
    JobsDB.db[:gemstack_jobs].delete
    drain_record
    super
  end
end
