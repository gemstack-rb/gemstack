# frozen_string_literal: true

require "test_helper"

class WebSocketCodecTest < Minitest::Test
  Codec = GemStack::Realtime::WebSocket::Codec

  # A client frame: masked, as browsers send them.
  def client_frame(payload, opcode: 0x1, fin: true, mask: "abcd".b)
    payload = payload.b
    head = [(fin ? 0x80 : 0) | opcode].pack("C")
    length = payload.bytesize
    head << if length < 126 then [0x80 | length].pack("C")
            elsif length < 65_536 then [0x80 | 126, length].pack("Cn")
            else [0x80 | 127, length].pack("CQ>")
            end
    head + mask + Codec.unmask(payload, mask)
  end

  def parse(bytes, max: 1024)
    messages = []
    parser = Codec::Parser.new(max_message_size: max)
    parser.feed(bytes) { |message| messages << message }
    messages
  end

  def test_handshake_accept_key_from_rfc_6455
    assert_equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", Codec.accept_key("dGhlIHNhbXBsZSBub25jZQ==")
    assert Codec.valid_key?("dGhlIHNhbXBsZSBub25jZQ==")
    refute Codec.valid_key?("short")
    assert_includes Codec.handshake_response("dGhlIHNhbXBsZSBub25jZQ=="), "101 Switching Protocols"
  end

  def test_text_messages_arriving_byte_by_byte
    bytes = client_frame("héllo") + client_frame("second")
    messages = []
    parser = Codec::Parser.new(max_message_size: 1024)
    bytes.each_char { |byte| parser.feed(byte) { |m| messages << m } }

    assert_equal [[:text, "héllo"], [:text, "second"]], messages
  end

  def test_fragmented_message_with_a_ping_in_between
    bytes = client_frame("Hel", fin: false) + client_frame("p", opcode: 0x9) + client_frame("lo", opcode: 0x0)

    assert_equal [[:ping, "p"], [:text, "Hello"]], parse(bytes)
  end

  def test_extended_lengths
    medium = "a" * 300
    large = "b" * 70_000

    assert_equal [[:text, medium]], parse(client_frame(medium))
    assert_equal [[:text, large]], parse(client_frame(large), max: 100_000)
  end

  def test_close_frames
    assert_equal [[:close, 1000, ""]], parse(client_frame("", opcode: 0x8))
    assert_equal [[:close, 1001, "bye"]], parse(client_frame("#{[1001].pack("n")}bye", opcode: 0x8))
  end

  def test_protocol_violations
    {
      "unmasked" => [["hi"].pack("a*").then { |p| [0x81, p.bytesize].pack("CC") + p }, Codec::PROTOCOL_ERROR],
      "reserved bits" => [client_frame("x").tap { |f| f.setbyte(0, f.getbyte(0) | 0x40) }, Codec::PROTOCOL_ERROR],
      "binary" => [client_frame("x", opcode: 0x2), Codec::UNSUPPORTED_DATA],
      "invalid utf-8" => [client_frame("\xFF\xFE"), Codec::INVALID_PAYLOAD],
      "too big" => [client_frame("x" * 2000), Codec::MESSAGE_TOO_BIG],
      "fragmented control" => [client_frame("p", opcode: 0x9, fin: false), Codec::PROTOCOL_ERROR],
      "orphan continuation" => [client_frame("x", opcode: 0x0), Codec::PROTOCOL_ERROR],
      "unknown opcode" => [client_frame("x", opcode: 0x3), Codec::PROTOCOL_ERROR]
    }.each do |name, (bytes, code)|
      error = assert_raises(Codec::Error, name) { parse(bytes) }

      assert_equal code, error.code, name
    end
  end

  def test_too_big_is_refused_from_the_header_alone
    header_only = [0x81, 0x80 | 127, 10_000_000].pack("CCQ>")

    assert_equal Codec::MESSAGE_TOO_BIG, assert_raises(Codec::Error) { parse(header_only) }.code
  end

  def test_server_frames_are_final_and_unmasked
    assert_equal [0x81, 2, "hi"].pack("CCa*"), Codec.text("hi")
    assert_equal [0x81, 126, 300].pack("CCn"), Codec.text("a" * 300).byteslice(0, 4)
    assert_equal [0x81, 127, 70_000].pack("CCQ>"), Codec.text("a" * 70_000).byteslice(0, 10)
    assert_equal [0x88, 2, 1000].pack("CCn"), Codec.close(1000)
    assert_equal [0x8A, 1, "x"].pack("CCa*"), Codec.pong("x")
  end
end
