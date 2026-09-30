# frozen_string_literal: true

# Rack entry point. Works with Puma (config/puma.rb) or any Rack server.
require_relative "config/app"

run GemStack.boot!
