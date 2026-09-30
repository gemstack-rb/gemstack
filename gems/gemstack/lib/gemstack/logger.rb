# frozen_string_literal: true

require "json"
require "time"

module GemStack
  # Structured, thread-safe logger.
  #
  #   logger.info("request", method: "GET", path: "/api/products", status: 200)
  #   logger.debug { "expensive #{computation}" }
  #   logger.with(request_id: id).warn("slow query", ms: 812)
  #
  # Formats:
  #   :pretty  12:00:01.123 INFO  request method=GET path=/api/products status=200
  #   :json    {"time":"...","level":"info","msg":"request","method":"GET",...}
  #
  # Fields whose key matches a filter (e.g. "password", "token") are replaced
  # with "[FILTERED]", recursively. It also answers the standard ::Logger
  # methods (#info, #level=, #debug?, ...) so it can be handed to other gems.
  class Logger
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3, fatal: 4 }.freeze
    LABELS = { debug: "DEBUG", info: "INFO ", warn: "WARN ", error: "ERROR", fatal: "FATAL" }.freeze
    COLORS = { debug: 90, info: 36, warn: 33, error: 31, fatal: 35 }.freeze
    FILTERED = "[FILTERED]"

    attr_reader :level, :format, :context

    def initialize(output = $stdout, level: :info, format: :pretty, filter: [], context: {}, color: nil, mutex: nil)
      @output = output
      # Log lines must appear when written, also when stdout is a pipe (e.g.
      # under `gemstack dev` or a process manager) where Ruby would buffer them.
      @output.sync = true if @output.respond_to?(:sync=)
      self.level = level
      @format = format.to_sym
      @filter = Array(filter).map { |f| f.to_s.downcase }
      @context = context
      @color = color.nil? ? output.respond_to?(:tty?) && output.tty? : color
      @mutex = mutex || Mutex.new
    end

    def level=(value)
      value = value.to_s.downcase.to_sym
      raise ArgumentError, "unknown log level #{value.inspect}" unless LEVELS.key?(value)

      @level = value
    end

    # A child logger that adds fields to every entry. Shares output and lock.
    def with(**fields)
      self.class.new(@output, level: @level, format: @format, filter: @filter, context: @context.merge(fields),
                              color: @color, mutex: @mutex)
    end

    LEVELS.each_key do |name|
      define_method(name) { |message = nil, **fields, &block| log(name, message, fields, &block) }
      define_method(:"#{name}?") { enabled?(name) }
    end

    def enabled?(severity) = @output && LEVELS.fetch(severity) >= LEVELS.fetch(@level)

    # ::Logger compatibility: `add(severity_int, message)`.
    def add(severity, message = nil, progname = nil, &)
      name = LEVELS.key(severity) || :info
      log(name, message || progname, {}, &)
    end

    def <<(message) = info(message.to_s.chomp)

    def filter(fields)
      return fields if @filter.empty?

      fields.to_h do |key, value|
        if filtered_key?(key) then [key, FILTERED]
        elsif value.is_a?(Hash) then [key, filter(value)]
        else [key, value]
        end
      end
    end

    private

    def log(severity, message, fields)
      return true unless enabled?(severity)

      message = yield if message.nil? && block_given?
      fields = filter(@context.empty? ? fields : @context.merge(fields))
      line = @format == :json ? json_line(severity, message, fields) : pretty_line(severity, message, fields)
      @mutex.synchronize { @output.write(line) }
      true
    rescue IOError, SystemCallError
      true # never let logging take the application down
    end

    def filtered_key?(key)
      key = key.to_s.downcase
      @filter.any? { |f| key.include?(f) }
    end

    def json_line(severity, message, fields)
      entry = { time: Time.now.utc.iso8601(3), level: severity, msg: message.to_s }
      fields.each { |key, value| entry[key] = serializable(value) }
      "#{JSON.generate(entry)}\n"
    end

    def pretty_line(severity, message, fields)
      label = LABELS[severity]
      label = "\e[#{COLORS[severity]}m#{label}\e[0m" if @color
      pairs = fields.map { |key, value| "#{key}=#{pretty_value(value)}" }
      [Time.now.strftime("%H:%M:%S.%L"), label, message, *pairs].join(" ") << "\n"
    end

    def pretty_value(value)
      case value
      when String then value.match?(/[\s"=]/) ? value.inspect : value
      when nil then "nil"
      when Hash, Array then JSON.generate(serializable(value))
      else value.to_s
      end
    end

    def serializable(value)
      case value
      when String, Integer, Float, true, false, nil then value
      when Hash then value.transform_values { |v| serializable(v) }
      when Array then value.map { |v| serializable(v) }
      when Exception then { class: value.class.name, message: value.message }
      else value.to_s
      end
    end
  end
end
