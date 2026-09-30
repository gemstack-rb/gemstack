# frozen_string_literal: true

module GemStack
  module HTTP
    module Middleware
      # Rejects request bodies larger than config.http.max_body_size.
      # Declared sizes (Content-Length) are rejected up front; bodies of
      # unknown size (chunked) are counted while being read.
      class BodyLimit
        # Wraps rack.input and raises PayloadTooLarge once the limit is passed.
        class LimitedInput
          def initialize(input, limit)
            @input = input
            @limit = limit
            @read = 0
          end

          def read(length = nil, buffer = nil)
            data = @input.read(length, buffer)
            count(data)
          end

          def gets
            count(@input.gets)
          end

          def each
            while (line = gets)
              yield line
            end
          end

          def rewind
            @read = 0
            @input.rewind
          end

          def close = @input.close

          private

          def count(data)
            @read += data.bytesize if data
            raise PayloadTooLarge if @read > @limit

            data
          end
        end

        def initialize(app, config)
          @app = app
          @limit = config.max_body_size
        end

        def call(env)
          return @app.call(env) unless @limit

          length = env["CONTENT_LENGTH"]
          if length && !length.empty?
            raise PayloadTooLarge if length.to_i > @limit
          elsif (input = env[Rack::RACK_INPUT])
            env[Rack::RACK_INPUT] = LimitedInput.new(input, @limit)
          end
          @app.call(env)
        end
      end
    end
  end
end
