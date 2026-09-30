# frozen_string_literal: true

require "test_helper"

class MiddlewareStackTest < Minitest::Test
  include HTTPTestHelpers

  M = GemStack::HTTP::Middleware

  Tag = Struct.new(:app, :name) do
    def call(env)
      env["order"] = (env["order"] || []) << name
      app.call(env)
    end
  end

  def test_default_stack_order
    names = GemStack::HTTP::MiddlewareStack.default(build_config).names.map { |n| n.split("::").last }

    assert_equal %w[RequestId RequestLogger Compression ErrorHandler SecurityHeaders Cors BodyLimit HealthCheck ETags],
                 names
  end

  def test_editing_operations
    stack = GemStack::HTTP::MiddlewareStack.new
    stack.use(Tag, "b")
    stack.unshift(Tag, "a")
    stack.insert_after(1, Tag, "c")
    stack.insert_before(0, Tag, "first")
    stack.delete(0)
    stack.swap(2, Tag, "C")
    env = {}
    stack.build(->(e) { [200, {}, [e["order"].join]] }).call(env)

    assert_equal %w[a b C], env["order"]
  end

  def test_targets_by_class
    stack = GemStack::HTTP::MiddlewareStack.default(build_config)
    stack.delete(M::SecurityHeaders)
    stack.insert_before(M::ErrorHandler, Tag, "x")

    refute stack.include?(M::SecurityHeaders)
    assert_equal(4, stack.to_a.index { |e| e.klass == M::ErrorHandler })
    assert_raises(ArgumentError) { stack.delete(M::SecurityHeaders) }
  end

  def test_dup_is_independent
    stack = GemStack::HTTP::MiddlewareStack.default(build_config)
    copy = stack.dup
    copy.delete(M::Cors)

    assert stack.include?(M::Cors)
  end
end

class DefaultMiddlewareTest < Minitest::Test
  include HTTPTestHelpers

  M = GemStack::HTTP::Middleware
  OK = ->(_env) { [200, { "content-type" => "text/plain" }, ["ok"]] }

  def test_request_id_generated_and_propagated
    app = M::RequestId.new(OK, build_config)
    _, headers, = app.call(env_for("/"))

    assert_match(/\A\h{8}-/, headers["x-request-id"])
    _, headers, = app.call(env_for("/", "HTTP_X_REQUEST_ID" => "lb-123"))

    assert_equal "lb-123", headers["x-request-id"]
    _, headers, = app.call(env_for("/", "HTTP_X_REQUEST_ID" => "bad id\n<script>"))

    refute_equal "bad id\n<script>", headers["x-request-id"]
  end

  def test_request_id_untrusted
    config = build_config
    config.trust_request_id = false
    _, headers, = M::RequestId.new(OK, config).call(env_for("/", "HTTP_X_REQUEST_ID" => "lb-123"))

    refute_equal "lb-123", headers["x-request-id"]
  end

  def test_request_logger_logs_on_body_close
    io = StringIO.new
    logger = GemStack::Logger.new(io, color: false)
    _, _, body = M::RequestLogger.new(OK, logger: logger).call(env_for("/api/x?token=secret"))

    assert_empty io.string
    body.close

    assert_match(%r{INFO  GET /api/x status=200 ms=[\d.]+}, io.string)
    refute_includes io.string, "secret"
  end

  def test_error_handler_hides_details_in_production
    config = build_config
    config.show_exceptions = false
    status, headers, body = M::ErrorHandler.new(->(_) { raise "db password=hunter2" }, config).call(env_for("/"))
    payload = JSON.parse(body.join)

    assert_equal 500, status
    assert_equal "no-store", headers["cache-control"]
    assert_equal({ "code" => "internal_error", "message" => "Internal Server Error" }, payload["error"])
    refute_includes body.join, "hunter2"
  end

  def test_error_handler_renders_gemstack_errors
    app = ->(_) { raise GemStack::ValidationError.new(errors: { name: ["is required"] }) }
    status, _, body = M::ErrorHandler.new(app, build_config).call(env_for("/"))

    assert_equal 422, status
    assert_equal({ "name" => ["is required"] }, JSON.parse(body.join)["errors"])
  end

  def test_error_handler_renders_duck_typed_errors
    error = Class.new(StandardError) do
      def status = 409
      def code = "already_exists"
    end
    status, _, body = M::ErrorHandler.new(->(_) { raise error, "exists" }, build_config).call(env_for("/"))

    assert_equal 409, status
    assert_equal "exists", JSON.parse(body.join)["error"]["message"]
  end

  def test_security_headers_do_not_override
    app = ->(_) { [200, { "x-frame-options" => "SAMEORIGIN" }, []] }
    _, headers, = M::SecurityHeaders.new(app, build_config).call(env_for("/"))

    assert_equal "SAMEORIGIN", headers["x-frame-options"]
    assert_equal "nosniff", headers["x-content-type-options"]
    refute headers.key?("strict-transport-security")
  end

  def test_hsts_only_over_https
    config = build_config
    config.hsts = "max-age=1"
    app = M::SecurityHeaders.new(OK, config)

    refute app.call(env_for("http://x/"))[1].key?("strict-transport-security")
    assert_equal "max-age=1", app.call(env_for("https://x/"))[1]["strict-transport-security"]
    assert_equal "max-age=1",
                 app.call(env_for("/", "HTTP_X_FORWARDED_PROTO" => "https"))[1]["strict-transport-security"]
  end

  def test_body_limit_content_length
    config = build_config
    config.max_body_size = 10
    app = M::BodyLimit.new(OK, config)

    assert_raises(GemStack::PayloadTooLarge) { app.call(env_for("/", method: "POST", input: "x" * 11)) }
    assert_equal 200, app.call(env_for("/", method: "POST", input: "x" * 10))[0]
  end

  def test_body_limit_streamed_body
    config = build_config
    config.max_body_size = 10
    reader = ->(env) { [200, {}, [env["rack.input"].read]] }
    env = env_for("/", method: "POST", input: "x" * 50)
    env.delete("CONTENT_LENGTH")

    assert_raises(GemStack::PayloadTooLarge) { M::BodyLimit.new(reader, config).call(env) }
  end

  def test_health_check
    app = M::HealthCheck.new(->(_) { [404, {}, []] }, build_config)

    assert_equal [200, ['{"status":"ok"}']], app.call(env_for("/api/health")).values_at(0, 2)
    assert_empty app.call(env_for("/api/health", method: "HEAD"))[2]
    assert_equal 404, app.call(env_for("/api/health", method: "POST"))[0]
    assert_equal 404, app.call(env_for("/api/other"))[0]
  end

  def test_health_check_disabled
    config = build_config
    config.health_path = nil

    assert_equal 404, M::HealthCheck.new(->(_) { [404, {}, []] }, config).call(env_for("/api/health"))[0]
  end
end

class CorsTest < Minitest::Test
  include HTTPTestHelpers

  OK = ->(_env) { [200, {}, ["ok"]] }

  def cors(**settings)
    config = GemStack::HTTP::Config.new
    settings.each { |key, value| config.cors.public_send(:"#{key}=", value) }
    GemStack::HTTP::Middleware::Cors.new(OK, config)
  end

  def test_disabled_by_default
    _, headers, = cors.call(env_for("/", "HTTP_ORIGIN" => "https://evil.test"))

    refute headers.key?("access-control-allow-origin")
  end

  def test_allowed_origin
    _, headers, = cors(origins: ["https://app.test"]).call(env_for("/", "HTTP_ORIGIN" => "https://app.test"))

    assert_equal "https://app.test", headers["access-control-allow-origin"]
    assert_equal "Origin", headers["vary"]
  end

  def test_disallowed_origin
    _, headers, = cors(origins: [/\.app\.test\z/]).call(env_for("/", "HTTP_ORIGIN" => "https://evil.test"))

    refute headers.key?("access-control-allow-origin")
    assert_equal "Origin", headers["vary"]
  end

  def test_preflight
    env = env_for("/", method: "OPTIONS", "HTTP_ORIGIN" => "https://a.app.test",
                       "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "PATCH")
    status, headers, = cors(origins: [/\.app\.test\z/], credentials: true).call(env)

    assert_equal 204, status
    assert_equal "https://a.app.test", headers["access-control-allow-origin"]
    assert_equal "true", headers["access-control-allow-credentials"]
    assert_includes headers["access-control-allow-methods"], "PATCH"
  end

  def test_wildcard_with_credentials_is_rejected
    assert_raises(GemStack::ConfigurationError) { cors(origins: ["*"], credentials: true) }
  end
end

class JSONCodecTest < Minitest::Test
  Codec = GemStack::HTTP::JSONCodec

  Point = Struct.new(:x, :y)

  class Money
    def as_json = { cents: 100, currency: :usd }
  end

  def codecs = [Codec::Stdlib.new, Codec::Oj.new]

  def test_dump_native_and_coerced_values
    value = { a: 1, "b" => [true, nil, 1.5], time: Time.utc(2026, 1, 1), date: Date.new(2026, 2, 3),
              sym: :x, point: Point.new(1, 2), money: Money.new, set: Set[1] }
    expected = { "a" => 1, "b" => [true, nil, 1.5], "time" => "2026-01-01T00:00:00.000Z", "date" => "2026-02-03",
                 "sym" => "x", "point" => { "x" => 1, "y" => 2 }, "money" => { "cents" => 100, "currency" => "usd" },
                 "set" => [1] }

    codecs.each { |codec| assert_equal expected, JSON.parse(codec.dump(value)), codec.class.name }
  end

  def test_unknown_objects_raise
    codecs.each { |codec| assert_raises(TypeError) { codec.dump(Object.new) } }
  end

  def test_load_limits_nesting
    codecs.each do |codec|
      assert_equal({ "a" => [1] }, codec.load('{"a":[1]}'))
      assert_raises(JSON::NestingError, JSON::ParserError) { codec.load(("[" * 100) + ("]" * 100)) }
      assert_raises(JSON::ParserError) { codec.load("{bad") }
    end
  end

  def test_resolve
    assert_kind_of Codec::Stdlib, Codec.resolve(:json)
    custom = Struct.new(:x) do
      def dump(_) = "{}"
      def load(_) = {}
    end.new

    assert_same custom, Codec.resolve(custom)
    assert_raises(GemStack::ConfigurationError) { Codec.resolve(:yaml) }
    assert_raises(GemStack::ConfigurationError) { Codec.resolve(Object.new) }
  end
end
