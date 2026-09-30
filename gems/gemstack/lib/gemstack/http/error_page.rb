# frozen_string_literal: true

require "rbconfig"

module GemStack
  module HTTP
    # The development error page: shown instead of the JSON envelope when a
    # *browser* opens an API URL that raises (a 500 with show_exceptions on).
    # fetch() and API clients keep getting JSON. Self-contained HTML, no JS.
    module ErrorPage
      CONTEXT_LINES = 5

      module_function

      # A top-level navigation from a browser (not fetch/XHR or an API client).
      def browser?(env)
        dest = env["HTTP_SEC_FETCH_DEST"]
        return dest == "document" if dest

        env["HTTP_ACCEPT"].to_s.include?("text/html")
      end

      def render(exception, env, request_id: nil)
        html = page(exception, env, request_id)
        [500, { "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store",
                "content-security-policy" => "default-src 'none'; style-src 'unsafe-inline'" }, [html]]
      end

      def page(exception, env, request_id)
        frames = frames(exception)
        first_app = frames.find { |frame| frame[:app] }
        <<~HTML
          <!doctype html>
          <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{h(exception.class.name)} · GemStack</title><style>#{STYLE}</style></head>
          <body><main>
          <p class="tag">#{h(env[Rack::REQUEST_METHOD])} #{h(env[Rack::PATH_INFO])}#{" · request #{h(request_id)}" if request_id}</p>
          <h1>#{h(exception.class.name)}</h1>
          <pre class="message">#{h(exception.message)}</pre>
          #{source(first_app || frames.first)}
          #{cause(exception)}
          <h2>Backtrace</h2>
          <ol class="trace">#{frames.map { |frame| trace_line(frame) }.join}</ol>
          <p class="hint">Shown because <code>config.http.show_exceptions</code> is on (development). API clients get the
          JSON error envelope; production shows neither the message nor the backtrace.</p>
          </main></body></html>
        HTML
      end

      def frames(exception)
        root = GemStack.config.root.to_s
        Array(exception.backtrace).first(60).map do |line|
          file, number, label = line.match(/\A(.+?):(\d+)(?::in [`'](.*)')?/)&.captures
          relative = file&.start_with?("#{root}/") ? file.delete_prefix("#{root}/") : nil
          app = !relative.nil? && !relative.start_with?("vendor/", "tmp/") && !relative.include?("/gems/")
          { line: line, file: file, number: number&.to_i, label: label,
            display: app ? line.delete_prefix("#{root}/") : shorten(line), app: app }
        end
      end

      def source(frame)
        return "" unless frame && frame[:file] && File.file?(frame[:file])

        lines = File.readlines(frame[:file])
        from = [frame[:number] - CONTEXT_LINES, 1].max
        to = [frame[:number] + CONTEXT_LINES, lines.size].min
        rows = (from..to).map do |n|
          css = n == frame[:number] ? ' class="hit"' : ""
          "<span#{css}><i>#{n}</i>#{h(lines[n - 1].to_s.chomp)}</span>"
        end
        %(<h2>#{h(frame[:display].to_s.sub(/:in .*/, ""))}</h2><pre class="source">#{rows.join}</pre>)
      rescue SystemCallError, ArgumentError
        ""
      end

      def cause(exception)
        cause = exception.cause or return ""
        return "" if exception.message.include?(cause.message.to_s.lines.first.to_s.strip) # wrapped, already shown

        %(<p class="cause">Caused by <b>#{h(cause.class.name)}</b>: #{h(cause.message)}</p>)
      end

      def trace_line(frame)
        %(<li#{' class="app"' if frame[:app]}>#{h(frame[:display])}</li>)
      end

      # /…/gems/4.0.0/gems/sequel-5.108.0/lib/x.rb → sequel-5.108.0/lib/x.rb
      def shorten(line)
        prefixes = Gem.path.map { |dir| "#{dir}/gems/" } + ["#{RbConfig::CONFIG["rubylibdir"]}/"]
        prefix = prefixes.find { |dir| line.start_with?(dir) }
        prefix ? line.delete_prefix(prefix) : line
      end

      def h(value) = Rack::Utils.escape_html(value.to_s)

      STYLE = <<~CSS
        :root { color-scheme: light dark; --bg: #fff; --fg: #16181d; --muted: #5b6170; --panel: #f3f4f7; --hit: #fde2e2; --accent: #c53030; }
        @media (prefers-color-scheme: dark) { :root { --bg: #0f1115; --fg: #e6e8ee; --muted: #9aa0ad; --panel: #1b1f2a; --hit: #4a1d22; --accent: #ff7b7b; } }
        body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.5 system-ui, sans-serif; }
        main { max-width: 64rem; margin: 0 auto; padding: 2rem 1rem 4rem; }
        h1 { color: var(--accent); margin: .2rem 0; font-size: 1.6rem; overflow-wrap: anywhere; }
        h2 { font-size: .95rem; margin: 1.8rem 0 .5rem; color: var(--muted); font-weight: 600; overflow-wrap: anywhere; }
        pre, ol { background: var(--panel); border-radius: 8px; padding: .8rem 1rem; overflow-x: auto; font: 13px/1.55 ui-monospace, Menlo, monospace; }
        .message { white-space: pre-wrap; font-size: 14px; }
        .source span { display: block; } .source i { display: inline-block; width: 3.5em; color: var(--muted); font-style: normal; }
        .source .hit { background: var(--hit); } .trace { padding-left: 3rem; color: var(--muted); } .trace .app { color: var(--fg); font-weight: 600; }
        .tag, .hint, .cause { color: var(--muted); } code { font-family: ui-monospace, Menlo, monospace; }
      CSS
    end
  end
end
