# frozen_string_literal: true

module GemStack
  module Storage
    # Serves the :disk service's signed URLs:
    #   PUT <path>/<token>   stores the request body (type and size as signed)
    #   GET <path>/<token>   streams the file
    # Unsigned, expired or tampered tokens get 404/403; nothing else is exposed.
    class Endpoint
      def initialize(app) = @app = app

      def call(env)
        prefix = "#{Storage.config.path}/"
        path = env[Rack::PATH_INFO].to_s
        return @app.call(env) unless path.start_with?(prefix)

        token = path.delete_prefix(prefix)
        case env[Rack::REQUEST_METHOD]
        when "PUT" then put(env, token)
        when "GET", "HEAD" then get(env, token)
        else raise MethodNotAllowed.new(headers: { "allow" => "GET, HEAD, PUT" })
        end
      end

      private

      def service
        service = Storage.service
        raise NotFound unless service.is_a?(Services::Disk)

        service
      end

      def put(env, token)
        claims = Storage.verify(token, purpose: "disk-put") or raise Forbidden.new("Invalid or expired upload URL",
                                                                                   code: "invalid_signature")
        check_headers!(env, claims)
        service.upload(claims["k"], LimitedReader.new(env["rack.input"], claims["n"]))
        unless service.size(claims["k"]) == claims["n"]
          service.delete(claims["k"])
          raise BadRequest.new("The file is smaller than declared", code: "size_mismatch")
        end
        [201, { "content-length" => "0" }, []]
      rescue LimitedReader::TooLarge
        FileUtils.rm_f("#{service.path_for(claims["k"])}.part")
        raise PayloadTooLarge.new("The file is larger than declared", code: "size_mismatch")
      end

      def check_headers!(env, claims)
        type = env["CONTENT_TYPE"].to_s.split(";").first.to_s.strip.downcase
        if type != claims["t"]
          raise BadRequest.new("Content-Type must be #{claims["t"]}",
                               code: "content_type_mismatch")
        end

        length = Integer(env["CONTENT_LENGTH"].to_s, exception: false)
        return unless length && length != claims["n"]

        raise BadRequest.new("Content-Length must be #{claims["n"]}", code: "size_mismatch")
      end

      def get(env, token)
        claims = Storage.verify(token, purpose: "disk-get") or raise NotFound
        file = service.path_for(claims["k"])
        raise NotFound unless File.file?(file)

        disposition = claims["d"] == "inline" ? "inline" : "attachment"
        disposition += "; filename=\"#{claims["f"].gsub(/["\\\r\n]/, "")}\"" if claims["f"]
        headers = {
          "content-type" => Storage.content_type_for(claims["k"]), "content-length" => File.size(file).to_s,
          "content-disposition" => disposition, "cache-control" => "private, max-age=300",
          # Uploaded files are untrusted: never sniffed, never scripted.
          "x-content-type-options" => "nosniff", "content-security-policy" => "default-src 'none'; sandbox"
        }
        body = env[Rack::REQUEST_METHOD] == "HEAD" ? [] : FileBody.new(file)
        [200, headers, body]
      end

      # Reads at most `limit` bytes; more means the client lied about the size.
      class LimitedReader
        class TooLarge < StandardError; end

        def initialize(io, limit)
          @io = io
          @left = limit
        end

        def read(length = nil, buffer = nil)
          chunk = @io.read(length || 65_536, buffer)
          return chunk if chunk.nil?

          @left -= chunk.bytesize
          raise TooLarge if @left.negative?

          chunk
        end
      end

      class FileBody
        def initialize(path) = @path = path

        def each
          File.open(@path, "rb") do |file|
            while (chunk = file.read(65_536))
              yield chunk
            end
          end
        end
      end
    end
  end
end
