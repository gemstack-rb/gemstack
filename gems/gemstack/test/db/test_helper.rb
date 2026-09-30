# frozen_string_literal: true

ENV["GEMSTACK_ENV"] = "test"
require "gemstack/db"
require "gemstack/db/testing"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"

# These tests need a real PostgreSQL. Point GEMSTACK_TEST_DATABASE_URL at a
# server you can create databases on, e.g.
#   GEMSTACK_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:5432/gemstack_db_test bundle exec rake test:gemstack-db
module DBTest
  URL = ENV.fetch("GEMSTACK_TEST_DATABASE_URL", nil)

  def self.available?
    return @available if defined?(@available)

    @available = URL && begin
      GemStack.config.db.url = URL
      GemStack::DB::Tasks.create
      GemStack::DB.connection.test_connection
      true
    rescue Sequel::DatabaseError, Sequel::DatabaseConnectionError => e
      warn "PostgreSQL unavailable (#{e.message.lines.first.strip}); skipping database tests"
      false
    end
  end

  def setup
    skip "set GEMSTACK_TEST_DATABASE_URL to run database tests" unless DBTest.available?
    super
  end

  def db = GemStack::DB.connection
end

# Connect once, up front, so the connection doesn't depend on test order.
DBTest.available?
