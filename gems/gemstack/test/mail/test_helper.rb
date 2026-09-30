# frozen_string_literal: true

ENV["GEMSTACK_ENV"] = "test"
require "gemstack/mail"
require "gemstack/mail/testing"
require "minitest/autorun"
require "tmpdir"

GemStack.config.logger.output = nil
