# frozen_string_literal: true

ENV["GEMSTACK_ENV"] = "test"
require "gemstack/cli"
require "minitest/autorun"
require "stringio"
require "tmpdir"
