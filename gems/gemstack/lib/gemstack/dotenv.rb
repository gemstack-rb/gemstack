# frozen_string_literal: true

module GemStack
  # Minimal `.env` file support.
  #
  # Supported syntax:
  #   KEY=value
  #   export KEY=value
  #   KEY="double quoted, supports \n \t \" escapes"
  #   KEY='single quoted, literal'
  #   KEY=value # trailing comment (unquoted values only)
  #   # full-line comment
  #
  # Variables already present in the environment are never overwritten: the
  # real environment always wins over files.
  module Dotenv
    LINE = /\A\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*)\z/
    ESCAPES = { "n" => "\n", "t" => "\t", "r" => "\r", '"' => '"', "\\" => "\\" }.freeze

    module_function

    # Loads the given files (in order; earlier files take precedence) into env.
    # Returns the hash of variables that were actually set.
    def load(*files, env: ENV)
      loaded = {}
      files.flatten.each do |file|
        next unless File.file?(file)

        parse(File.read(file)).each do |key, value|
          next if env.key?(key) || loaded.key?(key)

          env[key] = value
          loaded[key] = value
        end
      end
      loaded
    end

    def parse(source)
      source.each_line.with_object({}) do |raw, vars|
        line = raw.chomp
        next if line.strip.empty? || line.lstrip.start_with?("#")

        match = LINE.match(line) or next
        vars[match[1]] = parse_value(match[2].strip)
      end
    end

    def parse_value(value)
      case value[0]
      when '"'
        body = value[1..][/\A((?:[^"\\]|\\.)*)"/, 1] || value[1..]
        body.gsub(/\\(.)/) { ESCAPES.fetch(::Regexp.last_match(1), "\\#{::Regexp.last_match(1)}") }
      when "'"
        value[1..][/\A([^']*)'/, 1] || value[1..]
      else
        value.sub(/\s+#.*\z/, "")
      end
    end
  end
end
