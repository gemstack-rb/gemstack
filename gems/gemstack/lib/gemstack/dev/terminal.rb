# frozen_string_literal: true

module GemStack
  module Dev
    # Serialised, prefixed, coloured output for multiple processes:
    #
    #   api     │ 12:00:01.120 INFO  GET /api/health status=200 ms=0.4
    #   next    │ ✓ Compiled / in 812ms
    class Terminal
      COLORS = { "api" => 35, "next" => 36, "gateway" => 33, "gemstack" => 32, "jobs" => 34 }.freeze
      WIDTH = 8

      def initialize(io = $stdout, color: io.respond_to?(:tty?) && io.tty?)
        @io = io
        @io.sync = true if @io.respond_to?(:sync=) # output may be a pipe or file
        @color = color
        @mutex = Mutex.new
      end

      attr_reader :color

      def line(name, text)
        prefix = paint(name.ljust(WIDTH), COLORS.fetch(name, 37))
        text = text.to_s.chomp
        @mutex.synchronize { @io.puts("#{prefix}│ #{text}") }
      end

      def puts(text = "")
        @mutex.synchronize { @io.puts(text) }
      end

      def paint(text, code) = @color ? "\e[#{code}m#{text}\e[0m" : text
      def bold(text) = @color ? "\e[1m#{text}\e[0m" : text
      def dim(text) = paint(text, 90)
      def green(text) = paint(text, 32)
      def red(text) = paint(text, 31)
      def yellow(text) = paint(text, 33)
    end
  end
end
