# frozen_string_literal: true

require "test_helper"

class StorageTest < Minitest::Test
  include Rack::Test::Methods
  include GemStack::Storage::Testing

  Storage = GemStack::Storage

  def app
    GemStack::HTTP::App.new(config: http_config, router: GemStack::HTTP::Router.new(prefix: "/api"))
  end

  def http_config
    GemStack::HTTP::Config.new.tap do |config|
      config.middleware.insert_before(GemStack::HTTP::Middleware::BodyLimit, Storage::Endpoint)
      config.max_body_size = 1024 # the endpoint enforces its own, signed limit
    end
  end

  def put_file(upload, body, type: upload[:headers]["content-type"])
    put upload[:url], body, "CONTENT_TYPE" => type
  end

  def test_direct_upload_round_trip
    content = "\x89PNG#{"x" * 2000}".b
    upload = Storage.direct_upload(filename: "My Cat!.PNG", content_type: "image/png", byte_size: content.bytesize)

    assert_match(%r{\Auploads/\d{4}/\d{2}/[0-9a-f-]{36}/My-Cat\.png\z}, upload[:key])
    assert_equal "PUT", upload[:method]
    put_file(upload, content)

    assert_equal 201, last_response.status
    assert_equal upload[:key], Storage.key_for_signed_id(upload[:signed_id])
    get Storage.url(upload[:key])

    assert_equal 200, last_response.status
    assert_equal content, last_response.body.b
    assert_equal "image/png", last_response.headers["content-type"]
    assert_equal "inline", last_response.headers["content-disposition"]
    assert_equal "nosniff", last_response.headers["x-content-type-options"]
    assert_includes last_response.headers["content-security-policy"], "sandbox"
  end

  def test_the_extension_follows_the_validated_type
    upload = Storage.direct_upload(filename: "evil.html", content_type: "image/png", byte_size: 10)

    assert upload[:key].end_with?("/evil.png")
  end

  def test_upload_validation
    error = assert_raises(Storage::InvalidUpload) do
      Storage.direct_upload(filename: "x.svg", content_type: "image/svg+xml", byte_size: 100 * 1024 * 1024)
    end

    assert_equal 422, error.status
    assert_equal ["\"image/svg+xml\" is not allowed"], error.errors[:content_type]
    assert_equal ["is too large (maximum 10 MB)"], error.errors[:byte_size]
    assert_raises(Storage::InvalidUpload) { Storage.direct_upload(filename: "x.png", content_type: "image/png", byte_size: "x") }
  end

  def test_wildcard_content_types
    GemStack.config.storage.allowed_content_types = ["image/*"]

    assert Storage.allowed_content_type?("image/heic")
    refute Storage.allowed_content_type?("text/html")
  ensure
    GemStack.config.storage.allowed_content_types = GemStack::Storage::Config.new.allowed_content_types
  end

  def test_signed_upload_urls_are_enforced
    upload = Storage.direct_upload(filename: "a.png", content_type: "image/png", byte_size: 4)
    put_file(upload, "abcd", type: "text/html")

    assert_equal 400, last_response.status
    put_file(upload, "abcdef")

    assert_equal 400, last_response.status
    assert_equal "size_mismatch", JSON.parse(last_response.body).dig("error", "code")
    put "#{upload[:url]}x", "abcd", "CONTENT_TYPE" => "image/png"

    assert_equal 403, last_response.status
    refute Storage.exist?(upload[:key])
  end

  def test_body_larger_than_declared_without_content_length
    upload = Storage.direct_upload(filename: "a.png", content_type: "image/png", byte_size: 4)
    env = Rack::MockRequest.env_for(upload[:url], method: "PUT", input: "abcdefgh",
                                                  "CONTENT_TYPE" => "image/png")
    env.delete("CONTENT_LENGTH")
    status, = app.call(env)

    assert_equal 413, status
    refute Storage.exist?(upload[:key])
  end

  def test_expired_and_tampered_tokens
    key = Storage.generate_key("uploads", "a.pdf", "application/pdf")
    Storage.upload(key, StringIO.new("%PDF"), content_type: "application/pdf")
    get Storage.url(key, expires_in: -1)

    assert_equal 404, last_response.status
    assert_nil Storage.verify(Storage.sign("x", purpose: "upload"), purpose: "disk-get"), "purposes don't mix"
    assert_raises(Storage::InvalidUpload) { Storage.key_for_signed_id("#{Storage.sign(key, purpose: "upload")}0") }
  end

  def test_downloads_of_other_types_are_attachments
    key = Storage.generate_key("exports", "report.zip", "application/zip")
    Storage.upload(key, StringIO.new("PK"), content_type: "application/zip")
    get Storage.url(key, filename: "Report \"Q3\".zip")

    assert_equal 'attachment; filename="Report Q3.zip"', last_response.headers["content-disposition"]
  end

  def test_disk_keys_cannot_escape_the_root
    %w[../etc/passwd /etc/passwd a/../../b .hidden].each do |key|
      assert_raises(ArgumentError) { Storage.service.path_for(key) }
    end
  end

  def test_upload_fixture_helper
    signed = upload_fixture("png bytes")

    assert_equal "png bytes", Storage.download(Storage.key_for_signed_id(signed))
  end
end
