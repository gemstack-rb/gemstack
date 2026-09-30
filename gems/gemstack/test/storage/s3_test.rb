# frozen_string_literal: true

require "test_helper"
require "gemstack/storage/services/s3"

class S3Test < Minitest::Test
  def service
    @service ||= GemStack::Storage::Services::S3.new(
      bucket: "shop-uploads", region: "eu-west-3",
      client: Aws::S3::Client.new(stub_responses: true, region: "eu-west-3",
                                  credentials: Aws::Credentials.new("AKIDEXAMPLE", "secret"))
    )
  end

  def test_presigned_upload_signs_type_and_size
    upload = service.presigned_upload("uploads/a.png", content_type: "image/png", byte_size: 1234, expires_in: 300)
    uri = URI(upload[:url])
    signed = URI.decode_www_form(uri.query).to_h["X-Amz-SignedHeaders"]

    assert_equal "shop-uploads.s3.eu-west-3.amazonaws.com", uri.host
    assert_equal "/uploads/a.png", uri.path
    assert_includes signed.split(";"), "content-type"
    assert_includes signed.split(";"), "content-length"
    assert_equal "300", URI.decode_www_form(uri.query).to_h["X-Amz-Expires"]
  end

  def test_download_url_sets_disposition
    url = service.url("uploads/a.pdf", expires_in: 60, disposition: "attachment", filename: "a\".pdf")

    assert_includes URI.decode_www_form(URI(url).query).to_h["response-content-disposition"], 'attachment; filename="a.pdf"'
  end

  def test_exist_and_delete
    service.client.stub_responses(:head_object, "NotFound")

    refute service.exist?("nope")
    assert service.delete("x")
  end

  def test_bucket_is_required
    assert_raises(GemStack::ConfigurationError) { GemStack::Storage::Services::S3.new(bucket: nil, region: "x") }
  end

  def test_compatible_endpoint_uses_path_style
    s3 = GemStack::Storage::Services::S3.new(bucket: "b", region: "auto", endpoint: "http://localhost:9000",
                                             access_key_id: "a", secret_access_key: "b")
    url = s3.presigned_upload("k.png", content_type: "image/png", byte_size: 1, expires_in: 60)[:url]

    assert url.start_with?("http://localhost:9000/b/k.png?")
  end
end
