# frozen_string_literal: true

ENV["GEMSTACK_ENV"] = "test"
ENV["SECRET_KEY_BASE"] ||= "test-secret-#{"x" * 64}"
require "gemstack/storage"
require "gemstack/storage/testing"
require "minitest/autorun"
require "rack/test"

GemStack.config.logger.output = nil
