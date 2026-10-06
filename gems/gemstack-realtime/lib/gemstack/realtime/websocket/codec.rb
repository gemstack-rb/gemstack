# frozen_string_literal: true

require "digest/sha1"

module GemStack
  module Realtime
    module WebSocket
      # The wire format of RFC 6455 for the server side: the opening handshake,
      # an incremental frame parser for (masked) client frames and the encoder
      # for (unmasked) server frames. No extensions are negotiated. It only
      # turns bytes into messages and back; Connection decides what they mean,
      # so another implementation can replace it.
      module Codec
        GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

        OPCODES = { continuation: 0x0, text: 0x1, binary: 0x2, close: 0x8, ping: 0x9, pong: 0xA }.freeze
        NAMES = OPCODES.invert.freeze

        # Close codes (RFC 6455 §7.4.1).
        NORMAL = 1000
        GOING_AWAY = 1001
        PROTOCOL_ERROR = 1002
        UNSUPPORTED_DATA = 1003
        INVALID_PAYLOAD = 1007
        POLICY_VIOLATION = 1008
        MESSAGE_TOO_BIG = 1009
        INTERNAL_ERROR = 1011

        class Error < StandardError
          attr_reader :code

          def initialize(message, code: PROTOCOL_ERROR)
            super(message)
            @code = code
          end
        end

        module_function

        # Sec-WebSocket-Accept for a client's Sec-WebSocket-Key.
        def accept_key(key) = [Digest::SHA1.digest("#{key}#{GUID}")].pack("m0")

        # A valid Sec-WebSocket-Key is 16 random bytes, base64-encoded.
        def valid_key?(key) = key.to_s.match?(%r{\A[A-Za-z0-9+/]{22}==\z})

        def handshake_response(key)
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
            "Sec-WebSocket-Accept: #{accept_key(key)}\r\n\r\n"
        end

        def text(string) = frame(:text, string.encode(Encoding::UTF_8))
        def ping(payload = "") = frame(:ping, payload)
        def pong(payload = "") = frame(:pong, payload)
        def close(code = NORMAL, reason = "") = frame(:close, [code].pack("n") + reason.to_s.byteslice(0, 123))

        # One final, unmasked frame.
        def frame(type, payload)
          payload = payload.b
          length = payload.bytesize
          head = [0x80 | OPCODES.fetch(type)].pack("C")
          head << if length < 126 then [length].pack("C")
                  elsif length < 65_536 then [126, length].pack("Cn")
                  else [127, length].pack("CQ>")
                  end
          head << payload
        end

        # Applies (or removes) a 4-byte masking key.
        def unmask(payload, mask)
          return payload if payload.empty?

          key = mask.unpack("C4")
          bytes = payload.unpack("C*")
          bytes.each_index { |i| bytes[i] ^= key[i & 3] }
          bytes.pack("C*")
        end

        # feed(bytes) yields [:text, String] / [:ping, String] / [:pong, String] /
        # [:close, code, reason] as complete messages arrive (fragmented messages
        # are reassembled; control frames may arrive between fragments). Raises
        # Codec::Error, with the close code to send, on any protocol violation.
        class Parser
          def initialize(max_message_size:)
            @max = max_message_size
            @buffer = String.new(encoding: Encoding::BINARY)
            @fragments = nil
          end

          def feed(bytes)
            @buffer << bytes.b
            while (frame = next_frame)
              message = assemble(*frame)
              yield message if message
            end
          end

          private

          # [opcode, fin, payload] of the next complete frame, or nil.
          def next_frame
            return nil if @buffer.bytesize < 2

            first, second = @buffer.unpack("CC")
            raise Error, "reserved bits set (no extensions are negotiated)" if first.anybits?(0x70)
            raise Error, "client frames must be masked" unless second.anybits?(0x80)

            fin = first.anybits?(0x80)
            opcode = first & 0x0F
            length, offset = payload_length(second & 0x7F)
            return nil unless length

            control = opcode >= 0x8
            raise Error, "control frames can't be fragmented or exceed 125 bytes" if control && (!fin || length > 125)
            raise Error.new("message is larger than #{@max} bytes", code: MESSAGE_TOO_BIG) if length > @max
            return nil if @buffer.bytesize < offset + 4 + length

            mask = @buffer.byteslice(offset, 4)
            payload = Codec.unmask(@buffer.byteslice(offset + 4, length), mask)
            @buffer = @buffer.byteslice(offset + 4 + length, @buffer.bytesize)
            [opcode, fin, payload]
          end

          def payload_length(short)
            case short
            when 126
              return nil if @buffer.bytesize < 4

              [@buffer.byteslice(2, 2).unpack1("n"), 4]
            when 127
              return nil if @buffer.bytesize < 10

              length = @buffer.byteslice(2, 8).unpack1("Q>")
              raise Error, "invalid payload length" if length >= 2**63

              [length, 10]
            else [short, 2]
            end
          end

          def assemble(opcode, fin, payload)
            case NAMES[opcode]
            when :ping, :pong then [NAMES[opcode], payload]
            when :close then close_frame(payload)
            when :text, :binary then start_message(opcode, fin, payload)
            when :continuation then continue_message(fin, payload)
            else raise Error, "unknown opcode #{opcode}"
            end
          end

          def close_frame(payload)
            return [:close, NORMAL, ""] if payload.empty?
            raise Error, "close frame with a 1-byte payload" if payload.bytesize == 1

            reason = payload.byteslice(2, payload.bytesize).force_encoding(Encoding::UTF_8)
            raise Error.new("close reason isn't UTF-8", code: INVALID_PAYLOAD) unless reason.valid_encoding?

            [:close, payload.unpack1("n"), reason]
          end

          def start_message(opcode, fin, payload)
            raise Error, "new message before the previous one finished" if @fragments

            @type = opcode
            @fragments = payload
            fin ? finish_message : nil
          end

          def continue_message(fin, payload)
            raise Error, "continuation frame without a message" unless @fragments
            if @fragments.bytesize + payload.bytesize > @max
              raise Error.new("message is larger than #{@max} bytes", code: MESSAGE_TOO_BIG)
            end

            @fragments << payload
            fin ? finish_message : nil
          end

          def finish_message
            data = @fragments
            @fragments = nil
            raise Error.new("binary messages aren't supported", code: UNSUPPORTED_DATA) if @type == OPCODES[:binary]

            text = data.force_encoding(Encoding::UTF_8)
            raise Error.new("text message isn't valid UTF-8", code: INVALID_PAYLOAD) unless text.valid_encoding?

            [:text, text]
          end
        end
      end
    end
  end
end
