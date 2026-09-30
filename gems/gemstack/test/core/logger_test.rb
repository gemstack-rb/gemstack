# frozen_string_literal: true

require "test_helper"

class LoggerTest < Minitest::Test
  def setup
    @io = StringIO.new
  end

  def logger(**)
    GemStack::Logger.new(@io, color: false, **)
  end

  def test_pretty_format
    logger.info("request", method: "GET", path: "/api/x y", status: 200)

    assert_match(%r{\A\d\d:\d\d:\d\d\.\d{3} INFO  request method=GET path="/api/x y" status=200\n\z}, @io.string)
  end

  def test_json_format
    logger(format: :json).warn("slow", ms: 12.5, nested: { a: 1 })
    entry = JSON.parse(@io.string)

    assert_equal "warn", entry["level"]
    assert_equal "slow", entry["msg"]
    assert_in_delta 12.5, entry["ms"]
    assert_equal({ "a" => 1 }, entry["nested"])
    assert entry["time"]
  end

  def test_level_filtering
    log = logger(level: :warn)
    log.info("hidden")
    log.error("shown")

    refute_includes @io.string, "hidden"
    assert_includes @io.string, "shown"
    refute_predicate log, :info?
  end

  def test_block_messages_are_lazy
    called = false
    logger(level: :info).debug do
      called = true
      "x"
    end

    refute called
  end

  def test_filters_sensitive_keys_recursively
    logger(filter: %w[password token]).info("params", params: { "password" => "hunter2", "name" => "a" },
                                                      access_token: "abc")

    refute_includes @io.string, "hunter2"
    refute_includes @io.string, "abc"
    assert_includes @io.string, "[FILTERED]"
  end

  def test_with_adds_context
    logger.with(request_id: "r1").info("hi", x: 1)

    assert_includes @io.string, "request_id=r1 x=1"
  end

  def test_nil_output_disables
    log = GemStack::Logger.new(nil)

    refute_predicate log, :info?
    assert log.info("nothing")
  end

  def test_std_logger_compat
    logger.add(2, "warned")

    assert_includes @io.string, "WARN  warned"
  end

  def test_output_is_unbuffered
    reader, writer = IO.pipe
    GemStack::Logger.new(writer, color: false).info("now")

    assert_includes reader.read_nonblock(100), "now"
  ensure
    [reader, writer].each { |io| io&.close }
  end

  def test_invalid_level
    assert_raises(ArgumentError) { logger(level: :loud) }
  end
end
