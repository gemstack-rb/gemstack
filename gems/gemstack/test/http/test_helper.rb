# frozen_string_literal: true

ENV["GEMSTACK_ENV"] = "test"
require "gemstack/http"
require "minitest/autorun"
require "rack/test"
require "stringio"

module HTTPTestHelpers
  def build_config
    GemStack::HTTP::Config.new
  end

  def env_for(path, method: "GET", **)
    Rack::MockRequest.env_for(path, method: method, **)
  end

  def json(response)
    JSON.parse(response.respond_to?(:body) ? response.body : response[2].join)
  end
end
