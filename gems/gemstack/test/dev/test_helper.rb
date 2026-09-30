# frozen_string_literal: true

ENV["GEMSTACK_ENV"] = "test"
require "gemstack/dev"
require "minitest/autorun"
require "net/http"
require "socket"
require "stringio"
require "tmpdir"

# A raw TCP server standing in for Puma or Next.js. The handler receives the
# socket and the parsed request head.
class FakeUpstream
  attr_reader :port, :requests

  def initialize(&handler)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = Queue.new
    @thread = Thread.new do
      loop do
        socket = @server.accept
        Thread.new(socket) do |s|
          head = +""
          head << s.readpartial(4096) until head.include?("\r\n\r\n")
          @requests << head
          handler.call(s, head)
        rescue IOError, SystemCallError
          nil
        ensure
          s.close unless s.closed?
        end
      end
    rescue IOError
      nil
    end
  end

  def stop = @server.close

  def self.respond(socket, body, status: "200 OK", type: "text/plain")
    socket.write("HTTP/1.1 #{status}\r\ncontent-type: #{type}\r\ncontent-length: #{body.bytesize}\r\n" \
                 "connection: close\r\n\r\n#{body}")
  end
end
