# frozen_string_literal: true

require_relative "test_helper"

class HealthTest < GemStack::TestCase
  def test_api_boots_and_answers_health_checks
    get_json "/api/health"

    assert_status 200
    assert_equal({ "status" => "ok" }, json_body)
  end

  def test_unknown_routes_return_json_errors
    get_json "/api/does-not-exist"

    assert_error 404, "route_not_found"
  end
end
