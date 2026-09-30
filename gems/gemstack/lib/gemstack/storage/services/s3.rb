# frozen_string_literal: true

begin
  require "aws-sdk-s3"
rescue LoadError
  raise GemStack::ConfigurationError, "config.storage.service = :s3 needs gem \"aws-sdk-s3\" in the Gemfile"
end

module GemStack
  module Storage
    module Services
      # Amazon S3 and S3-compatible services (Cloudflare R2, MinIO, …).
      # Browsers PUT directly to a presigned URL; its signature covers the
      # content type and exact size, so neither can be changed.
      #
      # The bucket needs a CORS rule allowing PUT from your site (docs/storage.md).
      class S3
        attr_reader :bucket, :client

        def initialize(bucket:, region:, endpoint: nil, client: nil, **options)
          raise ConfigurationError, "set S3_BUCKET (config.storage.bucket) to use the :s3 storage service" if
            bucket.to_s.empty? && client.nil?

          @bucket = bucket
          options = { region: region, endpoint: endpoint,
                      force_path_style: !endpoint.nil? || nil }.compact.merge(options)
          @client = client || Aws::S3::Client.new(**options)
          @presigner = Aws::S3::Presigner.new(client: @client)
        end

        def upload(key, io, content_type:)
          client.put_object(bucket: bucket, key: key, body: io, content_type: content_type)
          key
        end

        def download(key) = client.get_object(bucket: bucket, key: key).body.read

        def exist?(key)
          client.head_object(bucket: bucket, key: key)
          true
        rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
          false
        end

        def delete(key)
          client.delete_object(bucket: bucket, key: key)
          true
        end

        def presigned_upload(key, content_type:, byte_size:, expires_in:)
          url = @presigner.presigned_url(:put_object, bucket: bucket, key: key, content_type: content_type,
                                                      content_length: byte_size, expires_in: expires_in,
                                                      whitelist_headers: ["content-length"]) # sign the size too
          { url: url, method: "PUT", headers: { "content-type" => content_type } }
        end

        def url(key, expires_in:, disposition:, filename: nil)
          header = filename ? "#{disposition}; filename=\"#{filename.to_s.gsub(/["\\\r\n]/, "")}\"" : disposition
          @presigner.presigned_url(:get_object, bucket: bucket, key: key, expires_in: expires_in,
                                                response_content_disposition: header)
        end
      end
    end
  end
end
