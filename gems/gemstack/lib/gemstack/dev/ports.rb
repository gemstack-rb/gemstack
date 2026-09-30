# frozen_string_literal: true

require "socket"

module GemStack
  module Dev
    module Ports
      module_function

      # An unused TCP port on host, chosen by the OS.
      def free(host = "127.0.0.1")
        server = TCPServer.new(host, 0)
        server.addr[1]
      ensure
        server&.close
      end

      def open?(host, port, timeout: 0.5)
        Socket.tcp(host, port, connect_timeout: timeout).close
        true
      rescue SystemCallError, SocketError, IOError
        false
      end
    end
  end
end
