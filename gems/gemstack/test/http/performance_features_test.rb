# frozen_string_literal: true

require "test_helper"
require "zlib"

class CompressionTest < Minitest::Test
  include HTTPTestHelpers

  M = GemStack::HTTP::Middleware
  BIG = JSON.generate(Array.new(200) { |i| { id: i, name: "Product #{i}" } })

  def app_returning(body = BIG, type: "application/json", headers: {}, status: 200)
    ->(_env) { [status, { "content-type" => type }.merge(headers), [body]] }
  end

  def compress(app = app_returning, accept: "gzip, br", method: "GET", **settings)
    config = build_config
    settings.each { |key, value| config.compression.public_send(:"#{key}=", value) }
    M::Compression.new(app, config).call(env_for("/", method: method, "HTTP_ACCEPT_ENCODING" => accept))
  end

  def test_prefers_brotli_and_round_trips
    status, headers, body = compress

    assert_equal 200, status
    assert_equal "br", headers["content-encoding"]
    assert_equal BIG, Brotli.inflate(body.join)
    assert_equal body.join.bytesize.to_s, headers["content-length"]
    assert_equal "Accept-Encoding", headers["vary"]
  end

  def test_gzip_when_brotli_not_accepted_or_disabled
    _, headers, body = compress(accept: "gzip")

    assert_equal "gzip", headers["content-encoding"]
    assert_equal BIG, Zlib.gunzip(body.join)
    _, headers, = compress(encodings: %w[gzip])

    assert_equal "gzip", headers["content-encoding"]
  end

  def test_q_values
    mw = M::Compression.new(app_returning, build_config)

    assert_equal "gzip", mw.negotiate("br;q=0.2, gzip;q=0.8")
    assert_equal "br", mw.negotiate("*")
    assert_nil mw.negotiate("br;q=0, gzip;q=0")
    assert_nil mw.negotiate("identity")
    assert_equal "gzip", mw.negotiate("GZIP")
  end

  def test_skips
    small = compress(app_returning("{}"))

    assert_nil small[1]["content-encoding"]
    assert_equal ["{}"], small[2]
    assert_nil compress(app_returning(BIG, type: "image/png"))[1]["content-encoding"]
    assert_nil compress(app_returning(BIG, type: "text/event-stream"))[1]["content-encoding"]
    assert_nil compress(app_returning(BIG, headers: { "cache-control" => "no-transform" }))[1]["content-encoding"]
    encoded = compress(app_returning(BIG, headers: { "content-encoding" => "gzip" }))

    assert_equal ["gzip", [BIG]], [encoded[1]["content-encoding"], encoded[2]] # already encoded: untouched
    assert_nil compress(app_returning(BIG, status: 204))[1]["content-encoding"]
    assert_nil compress(app_returning(BIG, status: 304))[1]["content-encoding"]
    assert_nil compress(app_returning("", status: 101, headers: { "upgrade" => "websocket" }))[1]["content-encoding"],
               "WebSocket handshakes are never touched"
    assert_nil compress(method: "HEAD")[1]["content-encoding"]
    assert_nil compress(accept: nil)[1]["content-encoding"]
    assert_nil compress(enabled: false)[1]["content-encoding"]
  end

  def test_vary_is_set_even_when_not_compressing_compressible_types
    _, headers, = compress(accept: nil)

    assert_equal "Accept-Encoding", headers["vary"]
    _, headers, = compress(app_returning(BIG, headers: { "vary" => "Origin" }))

    assert_equal "Origin, Accept-Encoding", headers["vary"]
  end

  def test_streaming_bodies_are_left_alone
    stream = Object.new
    def stream.each = yield("chunk")
    app = ->(_) { [200, { "content-type" => "application/json" }, stream] }

    assert_same stream, compress(app)[2]
  end

  def test_strong_etags_become_weak
    _, headers, = compress(app_returning(BIG, headers: { "etag" => '"abc"' }))

    assert_equal 'W/"abc"', headers["etag"]
  end

  def test_body_is_closed
    closed = false
    body = Rack::BodyProxy.new([BIG]) { closed = true }
    compress(->(_) { [200, { "content-type" => "application/json" }, body] })

    assert closed
  end
end

class ETagsAndCachingTest < Minitest::Test
  include Rack::Test::Methods
  include HTTPTestHelpers

  Record = Struct.new(:id, :updated_at) do
    def cache_key = "record/#{id}-#{updated_at.to_i}"
  end

  class CachingController < GemStack::HTTP::Controller
    RECORD = Record.new(1, Time.utc(2026, 1, 1))

    def plain = render({ big: "x" * 50 })

    def show
      @renders = true
      render({ id: 1 }) if stale?(etag: RECORD, last_modified: RECORD.updated_at)
    end

    def cached
      cache_control max_age: 300, public: true, stale_while_revalidate: 30
      render({ ok: true })
    end

    def secret
      cache_control :no_store
      render({ ok: true })
    end

    def items = render(paginate(Array.new(53) { |i| { n: i } }))
  end

  def app
    router = GemStack::HTTP::Router.new(prefix: "/api", resolver: ->(_) { CachingController }).draw do
      %w[plain show cached secret items].each { |a| get "/#{a}", to: "caching##{a}" }
    end
    GemStack::HTTP::App.new(config: build_config, router: router)
  end

  def test_automatic_etag_and_304
    get "/api/plain"
    etag = last_response.headers["etag"]

    assert_match(%r{\AW/"\h+"\z}, etag)
    assert_equal "max-age=0, private, must-revalidate", last_response.headers["cache-control"]
    get "/api/plain", {}, "HTTP_IF_NONE_MATCH" => etag

    assert_equal 304, last_response.status
    assert_empty last_response.body
  end

  def test_stale_with_record_etag_and_last_modified
    get "/api/show"
    etag = last_response.headers["etag"]

    assert_equal 200, last_response.status
    assert_equal "Thu, 01 Jan 2026 00:00:00 GMT", last_response.headers["last-modified"]
    get "/api/show", {}, "HTTP_IF_NONE_MATCH" => etag

    assert_equal 304, last_response.status
    get "/api/show", {}, "HTTP_IF_MODIFIED_SINCE" => "Fri, 02 Jan 2026 00:00:00 GMT"

    assert_equal 304, last_response.status
    get "/api/show", {}, "HTTP_IF_NONE_MATCH" => 'W/"other"'

    assert_equal 200, last_response.status
  end

  def test_cache_control
    get "/api/cached"

    assert_equal "public, max-age=300, stale-while-revalidate=30", last_response.headers["cache-control"]
    get "/api/secret"

    assert_equal "no-store", last_response.headers["cache-control"]
  end

  def test_pagination
    get "/api/items"

    assert_equal({ "page" => 1, "per_page" => 25, "total" => 53, "total_pages" => 3 }, json(last_response)["meta"])
    assert_equal 25, json(last_response)["data"].size
    get "/api/items?page=3&per_page=25"

    assert_equal(3, json(last_response)["data"].size)
    get "/api/items?per_page=1000"

    assert_equal 100, json(last_response)["meta"]["per_page"]
    get "/api/items?page=99"

    assert_empty json(last_response)["data"]
    get "/api/items?page=0"

    assert_equal 422, last_response.status
    assert_equal ["must be greater than or equal to 1"], json(last_response)["errors"]["page"]
  end

  def test_no_page_constant_shadows_app_models_in_controllers
    refute GemStack::HTTP::Controller.const_defined?(:Page, false)
  end

  def test_page_type_marker
    type = GemStack::Page[String]

    assert_equal String, type.item
    assert_equal 0, GemStack::HTTP::Page.new([], page: 1, per_page: 10, total: 0).total_pages
  end
end
