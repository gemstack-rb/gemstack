# frozen_string_literal: true

require "zlib"

module GemStack
  module HTTP
    module Middleware
      # Response compression with content negotiation.
      #
      # - Negotiates Accept-Encoding (with q-values): Brotli when the `brotli`
      #   gem is available, otherwise gzip.
      # - Compresses only compressible types (JSON, text, JS, XML, SVG) with a
      #   known body at least `min_size` bytes long.
      # - Never touches: HEAD, 1xx/204/304, responses that already have a
      #   Content-Encoding, `Cache-Control: no-transform`, Server-Sent Events,
      #   or streamed bodies of unknown length.
      # - Always sends `Vary: Accept-Encoding` for compressible types, and
      #   weakens strong ETags of compressed responses.
      class Compression
        COMPRESSIBLE = %r{
          \A\s*(?:
            text/(?!event-stream)                                        # any text/*, except Server-Sent Events
          | application/(?:json|javascript|xml|[\w.+-]+\+(?:json|xml))  # JSON, JS, XML and +json/+xml types
          | image/svg\+xml
          )
        }xi

        def self.brotli_available?
          return @brotli_available if defined?(@brotli_available)

          @brotli_available = begin
            require "brotli"
            true
          rescue LoadError
            false
          end
        end

        def initialize(app, config)
          @app = app
          settings = config.compression
          @enabled = settings.enabled
          @min_size = settings.min_size
          @gzip_level = settings.gzip_level
          @brotli_quality = settings.brotli_quality
          @encodings = settings.encodings.map(&:to_s).select do |encoding|
            encoding == "gzip" || (encoding == "br" && self.class.brotli_available?)
          end
        end

        def call(env)
          status, headers, body = @app.call(env)
          return [status, headers, body] unless @enabled && eligible?(env, status, headers)

          vary(headers)
          encoding = negotiate(env["HTTP_ACCEPT_ENCODING"])
          return [status, headers, body] unless encoding && body.respond_to?(:to_ary)

          content = read(body)
          return [status, headers, [content]] if content.bytesize < @min_size

          compressed = encode(encoding, content)
          headers["content-encoding"] = encoding
          headers["content-length"] = compressed.bytesize.to_s
          headers["etag"] = "W/#{headers["etag"]}" if headers["etag"]&.start_with?('"')
          [status, headers, [compressed]]
        end

        # "gzip;q=0.5, br" → "br". Server preference order breaks ties; q=0 refuses.
        def negotiate(header)
          return nil if header.nil? || header.empty? || @encodings.empty?

          accepted = header.split(",").to_h do |part|
            name, *params = part.strip.split(";")
            q = params.find { |p| p.strip.start_with?("q=") }&.then { |p| p.strip[2..].to_f } || 1.0
            [name.to_s.strip.downcase, q]
          end
          wildcard = accepted.fetch("*", 0.0)
          ranked = @encodings.map { |encoding| [encoding, accepted.fetch(encoding, wildcard)] }
          best = ranked.select { |_, q| q.positive? }.max_by { |encoding, q| [q, -@encodings.index(encoding)] }
          best&.first
        end

        private

        def eligible?(env, status, headers)
          return false if env[Rack::REQUEST_METHOD] == "HEAD"
          return false if status < 200 || status == 204 || status == 304
          return false if headers["content-encoding"]
          return false if headers["cache-control"]&.include?("no-transform")

          COMPRESSIBLE.match?(headers["content-type"].to_s)
        end

        def vary(headers)
          current = headers["vary"]
          return if current&.split(",")&.any? { |v| %w[accept-encoding *].include?(v.strip.downcase) }

          headers["vary"] = current ? "#{current}, Accept-Encoding" : "Accept-Encoding"
        end

        def read(body)
          content = String.new(encoding: Encoding::BINARY)
          body.each { |part| content << part }
          content
        ensure
          body.close if body.respond_to?(:close)
        end

        def encode(encoding, content)
          case encoding
          when "br" then Brotli.deflate(content, quality: @brotli_quality)
          else gzip(content)
          end
        end

        def gzip(content)
          io = StringIO.new(String.new(encoding: Encoding::BINARY))
          writer = Zlib::GzipWriter.new(io, @gzip_level)
          writer.write(content)
          writer.finish
          io.string
        end
      end
    end
  end
end
