# frozen_string_literal: true

require "openssl"
require "securerandom"
require "json"
require "time"
require "gemstack/core"
require "gemstack/http"

module GemStack
  # File storage: files go from the browser straight to
  # the storage service, never through a Ruby process.
  #
  #   # POST /api/uploads → presigned upload for the browser
  #   upload = GemStack::Storage.direct_upload(filename: "cat.png", content_type: "image/png", byte_size: 52_000)
  #   # browser: PUT the file to upload[:url] with upload[:headers]
  #   # later:   product.update(image_key: GemStack::Storage.key_for_signed_id(params[:image]))
  #   GemStack::Storage.url(product.image_key)   # short-lived signed download URL
  #
  # Services: :disk (development and tests; files under storage/, served and
  # accepted by a signed endpoint at /api/storage) and :s3 (S3, R2, MinIO…).
  module Storage
    class Config < Settings
      # :disk, :s3, or a service object.
      setting :service, default: -> { ENV.fetch("STORAGE_SERVICE", GemStack.env.production? ? "s3" : "disk").to_sym }
      setting :root, default: -> { File.join(GemStack.config.root, "storage", GemStack.env.test? ? "test" : "") }
      # Where the disk service's signed URLs point (handled by Storage::Endpoint).
      setting :path, default: -> { "#{GemStack.config.http.api_path}/storage" }
      setting :bucket, default: -> { ENV.fetch("S3_BUCKET", nil) }
      setting :region, default: -> { ENV.fetch("AWS_REGION", ENV.fetch("S3_REGION", "us-east-1")) }
      # For S3-compatible services: https://<account>.r2.cloudflarestorage.com, http://localhost:9000
      setting :endpoint, default: -> { ENV.fetch("S3_ENDPOINT", nil) }
      # Credentials come from the usual AWS chain (AWS_ACCESS_KEY_ID…, instance roles) unless set.
      setting :s3_options, default: {}
      setting :url_expires_in, default: 300
      setting :max_upload_size, default: 10 * 1024 * 1024
      # MIME types accepted by direct_upload ("image/*" style wildcards).
      # SVG and HTML are excluded on purpose: they can carry scripts.
      setting :allowed_content_types, default: %w[image/png image/jpeg image/gif image/webp image/avif application/pdf]
    end

    class InvalidUpload < ValidationError; end

    # Served inline by browsers; everything else is sent as an attachment.
    INLINE_TYPES = %w[image/png image/jpeg image/gif image/webp image/avif application/pdf text/plain].freeze

    class << self
      def config = GemStack.config.storage

      def service
        @service ||= build_service(config.service)
      end

      attr_writer :service

      def reset! = @service = nil

      # Validates an upload request and returns what the browser needs:
      #   { key:, signed_id:, url:, method: "PUT", headers: {…} }
      def direct_upload(filename:, content_type:, byte_size:, prefix: "uploads")
        content_type = content_type.to_s.downcase.split(";").first.to_s.strip
        byte_size = Integer(byte_size, exception: false)
        validate_upload!(content_type, byte_size)

        key = generate_key(prefix, filename, content_type)
        upload = service.presigned_upload(key, content_type: content_type, byte_size: byte_size,
                                               expires_in: config.url_expires_in)
        { key: key, signed_id: sign(key, purpose: "upload"), **upload }
      end

      # The key behind a signed_id from direct_upload; 422 when tampered with
      # (so clients can't point records at other people's files).
      def key_for_signed_id(signed_id)
        verify(signed_id, purpose: "upload") ||
          raise(InvalidUpload.new("Invalid upload reference", errors: { file: ["is invalid"] }))
      end

      def url(key, expires_in: config.url_expires_in, disposition: nil, filename: nil)
        service.url(key, expires_in: expires_in, disposition: disposition || disposition_for(key), filename: filename)
      end

      def upload(key, io, content_type:) = service.upload(key, io, content_type: content_type)
      def download(key) = service.download(key)
      def delete(key) = service.delete(key)
      def exist?(key) = service.exist?(key)

      def allowed_content_type?(type)
        Array(config.allowed_content_types).any? do |pattern|
          pattern.end_with?("/*") ? type.start_with?(pattern.delete_suffix("*")) : type == pattern
        end
      end

      # Tamper-proof, expiring tokens (HMAC with GemStack.key_for("storage")).
      def sign(value, purpose:, expires_in: nil)
        payload = { "v" => value, "p" => purpose }
        payload["e"] = Time.now.to_i + expires_in if expires_in
        data = [JSON.generate(payload)].pack("m0").tr("+/", "-_").delete("=")
        "#{data}--#{digest(data)}"
      end

      def verify(token, purpose:)
        data, mac = token.to_s.split("--", 2)
        return nil unless data && mac && OpenSSL.fixed_length_secure_compare(digest(data), mac)

        payload = JSON.parse(data.tr("-_", "+/").ljust((data.length + 3) & ~3, "=").unpack1("m0"))
        return nil unless payload["p"] == purpose
        return nil if payload["e"] && payload["e"] < Time.now.to_i

        payload["v"]
      rescue ArgumentError, JSON::ParserError
        nil
      end

      # Keys are ours, not the client's: uploads/2026/09/<uuid>/<clean name>.
      # The extension always matches the validated content type, so a file
      # declared as image/png can't be served as HTML because it's named x.html.
      def generate_key(prefix, filename, content_type)
        base = File.basename(filename.to_s, ".*").unicode_normalize(:nfkc).gsub(/[^\w-]+/, "-").gsub(/\A-+|-+\z/, "")
        base = "file" if base.empty?
        [prefix, Time.now.utc.strftime("%Y/%m"), SecureRandom.uuid, "#{base[0, 100]}#{extension_for(content_type)}"]
          .reject(&:empty?).join("/")
      end

      EXTENSIONS = { "image/jpeg" => ".jpg", "image/png" => ".png", "image/gif" => ".gif", "image/webp" => ".webp",
                     "image/avif" => ".avif", "application/pdf" => ".pdf", "text/plain" => ".txt",
                     "text/csv" => ".csv" }.freeze

      def extension_for(content_type) = EXTENSIONS[content_type] || Rack::Mime::MIME_TYPES.key(content_type) || ".bin"

      def content_type_for(key) = Rack::Mime.mime_type(File.extname(key.to_s), "application/octet-stream")

      private

      def build_service(service)
        case service
        when :disk, "disk" then Services::Disk.new(root: config.root, path: config.path)
        when :s3, "s3"
          require_relative "storage/services/s3"
          Services::S3.new(bucket: config.bucket, region: config.region, endpoint: config.endpoint,
                           **config.s3_options)
        else
          unless service.respond_to?(:presigned_upload)
            raise ConfigurationError, "unknown config.storage.service #{service.inspect} (use :disk, :s3 or an object)"
          end

          service
        end
      end

      def validate_upload!(content_type, byte_size)
        errors = {}
        errors[:content_type] = ["#{content_type.inspect} is not allowed"] unless allowed_content_type?(content_type)
        max = config.max_upload_size
        if byte_size.nil? || byte_size <= 0
          errors[:byte_size] = ["must be a positive number of bytes"]
        elsif byte_size > max
          errors[:byte_size] = ["is too large (maximum #{max / 1024 / 1024} MB)"]
        end
        raise InvalidUpload.new("Upload refused", errors: errors) unless errors.empty?
      end

      # Browsers show images and PDFs inline; anything else downloads.
      def disposition_for(key) = INLINE_TYPES.include?(content_type_for(key)) ? "inline" : "attachment"

      def digest(data) = OpenSSL::HMAC.hexdigest("SHA256", GemStack.key_for("storage"), data)
    end
  end
end

require_relative "storage/services/disk"
require_relative "storage/endpoint"

GemStack::Config.namespace(:storage, GemStack::Storage::Config)

GemStack::Plugins.register(:storage) do |app|
  next unless app.respond_to?(:config)

  stack = app.config.http.middleware
  # Before BodyLimit: signed uploads carry their own size limit.
  unless stack.include?(GemStack::Storage::Endpoint)
    stack.insert_before(GemStack::HTTP::Middleware::BodyLimit, GemStack::Storage::Endpoint)
  end
end
