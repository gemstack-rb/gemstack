# frozen_string_literal: true

require "cgi"
require "json"
require "openssl"
require "rack"
require "securerandom"
require "time"

module GemStack
  module Jobs
    # Small, self-contained Rack UI for inspecting the database-backed queue.
    # Route mounting is owned by Application; this app handles paths rooted at
    # config.jobs.dashboard.path and can also be called as a mounted Rack app.
    # rubocop:disable Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength, Layout/LineLength, Lint/DuplicateBranch, Style/StringConcatenation
    class DashboardApp
      FORM_LIMIT = 16 * 1024
      PAGE_SIZE = 25
      COOKIE = "gemstack_jobs_csrf"

      def initialize(config: Jobs.config.dashboard, dashboard: Dashboard.new)
        @config = config
        @dashboard = dashboard
      end

      def call(env)
        return response(404, "Not found") unless @config.enabled
        return response(404, "Not found") unless @config.authorized?(env)

        method = env.fetch(Rack::REQUEST_METHOD, "GET").upcase
        path = request_path(env)
        return response(404, "Not found") unless path

        if method == "HEAD"
          status, headers, = dispatch("GET", path, env)
          return [status, headers, []]
        end
        return response(405, "Method not allowed", "allow" => "GET, HEAD, POST") unless %w[GET POST].include?(method)

        dispatch(method, path, env)
      rescue ArgumentError => e
        response(400, e.message)
      rescue Dashboard::UnsupportedAdapter => e
        GemStack.logger.info("jobs dashboard unavailable", reason: e.message)
        response(503, "The jobs dashboard requires the database job adapter.")
      rescue StandardError => e
        if database_connection_error?(e) || missing_jobs_table_error?(e)
          log_exception("jobs dashboard database unavailable", e)
          return response(503, "The jobs dashboard is temporarily unavailable. Check the database and jobs migration.")
        end

        log_exception("jobs dashboard request failed", e)
        details = ("#{e.class}: #{e.message}\n\n#{Array(e.backtrace).join("\n")}" if GemStack.env.development?)
        response(500, "The jobs dashboard encountered an unexpected error.", details: details)
      end

      private

      def dispatch(method, path, env)
        request = Rack::Request.new(env)
        if method == "GET"
          case path
          when "/" then overview(env, request)
          when "/all" then jobs_index(env, request, nil)
          when "/ready", "/scheduled", "/running", "/failed", "/completed"
            jobs_index(env, request, path.delete_prefix("/"))
          when %r{\A/(\d+)\z} then job_detail(env, Regexp.last_match(1))
          # Legacy routes from the original dashboard URL layout.
          when "/jobs" then legacy_jobs_redirect(request)
          when %r{\A/jobs/(\d+)\z}
            redirect(route_url(:job, id: Regexp.last_match(1), **request.GET.to_h.transform_keys(&:to_sym)),
                     status: 301)
          else response(404, "Not found")
          end
        else
          case path
          when %r{\A/(\d+)/(retry|run_now|delete)\z}
            mutate(env, Regexp.last_match(1), Regexp.last_match(2), request)
          when %r{\A/bulk/(retry|run_now|delete)\z}
            bulk_mutate(env, request, Regexp.last_match(1))
          # Continue accepting old POST actions for forms already open in a browser.
          when %r{\A/jobs/(\d+)/(retry|discard|run-now|delete)\z}
            mutate(env, Regexp.last_match(1), Regexp.last_match(2), request)
          when "/jobs/bulk" then bulk_mutate(env, request, nil)
          else response(404, "Not found")
          end
        end
      end

      def overview(env, request)
        stats = @dashboard.stats
        listing = @dashboard.list(page: 1, per_page: PAGE_SIZE)
        counts = state_counts(stats)
        body = +%(<div class="page-heading"><div><p class="eyebrow">Queue monitor</p><h1>Overview</h1></div></div>)
        body << notice(request.GET["notice"])
        body << %(<section class="summary-grid" aria-label="Job totals">)
        %w[ready scheduled running failed completed].each do |state|
          body << %(<a class="summary-card" href="#{html_url(route_path(state.to_sym))}"><span>#{state.capitalize}</span><strong>#{counts[state]}</strong></a>)
        end
        body << %(<a class="summary-card total" href="#{html_url(route_path(:all))}"><span>Total</span><strong>#{counts.values.sum}</strong></a></section>)
        body << %(<section class="panel" id="queues"><div class="section-heading"><div><p class="eyebrow">Breakdown</p><h2>Queues</h2></div></div>)
        if stats.empty?
          body << %(<p class="empty">No jobs have been queued yet.</p>)
        else
          body << %(<div class="table-wrap"><table><thead><tr><th>Queue</th><th>Ready</th><th>Scheduled</th><th>Running</th><th>Failed</th><th>Completed</th><th>Total</th></tr></thead><tbody>)
          stats.sort.each do |queue, counts|
            body << %(<tr><th scope="row">#{h(queue)}</th>)
            %i[ready scheduled running failed completed].each do |state|
              body << %(<td><a href="#{html_url(route_path(state), queue: queue)}">#{counts[state].to_i}</a></td>)
            end
            body << %(<td><strong>#{counts.values.sum}</strong></td>)
            body << "</tr>"
          end
          body << "</tbody></table></div>"
        end
        body << "</section>"
        body << %(<section class="panel"><div class="section-heading"><div><p class="eyebrow">Latest activity</p><h2>Recent jobs</h2></div><a class="text-link" href="#{html_url(route_path(:all))}">View all jobs →</a></div>)
        body << jobs_table(listing, compact: true)
        body << "</section>"
        html(body, env: env, active: :overview)
      end

      def jobs_index(env, request, state)
        query = request.GET
        queue = query["queue"]
        page = query["page"] || "1"
        listing = @dashboard.list(state: state, queue: queue, page: page, per_page: PAGE_SIZE)
        last_page = [(listing[:total].to_f / listing[:per_page]).ceil, 1].max
        if listing[:page] > last_page
          listing = @dashboard.list(state: state, queue: queue, page: last_page,
                                    per_page: PAGE_SIZE)
        end
        stats = @dashboard.stats
        counts = state_counts(stats, queue: queue)
        title = state ? state.capitalize : "All jobs"
        body = %(<div class="page-heading"><div><p class="eyebrow">Queue monitor</p><h1>#{h(title)}</h1></div></div>)
        body << notice(query["notice"])
        body << state_tabs(state, queue, counts)
        body << queue_filter(state, queue, stats)
        body << jobs_table(listing, state: state, queue: queue, env: env)
        body << pagination(listing, state: state, queue: queue)
        html(body, env: env, active: state)
      end

      def job_detail(env, id)
        job = @dashboard.find(id)
        return response(404, "Job not found") unless job

        state = job_state(job)
        body = %(<p class="breadcrumbs"><a href="#{html_url(route_path(:all))}">Jobs</a> / Job ##{h(job[:id])}</p>)
        body << %(<section class="panel detail-panel"><div class="section-heading"><div><p class="eyebrow">Job ##{h(job[:id])}</p><h1>#{h(job[:job_class])}</h1></div><span class="state state-#{h(state)}">#{h(state)}</span></div>)
        body << %(<dl class="details">)
        fields = { "Queue" => job[:queue], "Priority" => job[:priority], "Attempts" => job[:attempts],
                   "Run at" => job[:run_at], "Enqueued at" => job[:created_at],
                   "Locked at" => job[:locked_at], "Locked by" => job[:locked_by],
                   "Failed at" => job[:failed_at], "Completed at" => job[:completed_at] }
        fields.each { |label, value| body << %(<div><dt>#{h(label)}</dt><dd>#{detail_value(value)}</dd></div>) }
        body << "</dl>"
        body << %(<section><h2>Arguments</h2><pre class="code">#{h(JSON.pretty_generate(job[:args]))}</pre></section>)
        if state == "failed"
          error_class, error_message, backtrace = error_parts(job[:last_error])
          error_class = "Error details unavailable" if error_class.empty? && error_message.empty?
          body << %(<section><h2>Error</h2><div class="error-card"><strong>#{h(error_class)}</strong><p>#{h(error_message.empty? ? "No error message recorded." : error_message)}</p></div>)
          trace = backtrace.empty? ? "No backtrace recorded." : backtrace
          body << %(<h3>Backtrace</h3><pre class="code trace">#{h(trace)}</pre></section>)
        end
        if state != "running"
          body << %(<div class="row-actions detail-actions">#{job_actions(job, state, env,
                                                                          return_to: "detail")}</div>)
        end
        body << "</section>"
        html(body, env: env, active: nil)
      end

      def mutate(env, id, action, request)
        unless env[Rack::REQUEST_METHOD].to_s.upcase == "POST"
          return response(405, "Method not allowed",
                          "allow" => "POST")
        end

        form = parse_form(env)
        return response(403, "Request verification failed") unless valid_csrf?(env, form["_csrf"])

        changed = case action
                  when "retry" then @dashboard.retry_failed(id)
                  when "discard" then @dashboard.discard_failed(id)
                  when "run_now", "run-now" then @dashboard.run_now(id)
                  when "delete" then request.GET["failed"] == "1" ? @dashboard.discard_failed(id) : @dashboard.delete_pending(id)
                  end
        return response(409, "This job has changed state and the action was not applied") unless changed

        return_to = request.GET["return_to"]
        route = %w[all ready scheduled running failed completed].include?(return_to) ? return_to.to_sym : nil
        route = :job if return_to == "detail" || (route.nil? && action == "retry")
        route ||= :overview
        redirect(route_url(route, id: route == :job ? id : nil, queue: request.GET["queue"],
                                  page: request.GET["page"], notice: action_notice(action)))
      end

      def bulk_mutate(env, _request, route_action)
        form = parse_form(env)
        return response(403, "Request verification failed") unless valid_csrf?(env, form["_csrf"])

        ids = form["ids"]
        ids = [ids] unless ids.nil? || ids.is_a?(Array)
        raise ArgumentError, "Select between 1 and 100 jobs" if ids.nil? || ids.empty? || ids.size > 100

        action = route_action || form["action"]
        action = "run-now" if action == "run_now"
        count = case action
                when "retry" then @dashboard.retry_failed_jobs(ids)
                when "delete" then @dashboard.delete_jobs(ids)
                when "run-now" then @dashboard.run_now_jobs(ids)
                else raise ArgumentError, "Unknown bulk action"
                end
        route = if %w[ready scheduled running failed completed
                      all].include?(form["return_to"])
                  form["return_to"].to_sym
                else
                  :all
                end
        redirect(route_url(route, queue: form["queue"], page: form["page"], notice: "bulk-#{action}-#{count}"))
      end

      def jobs_table(listing, state: nil, queue: nil, env: nil, compact: false)
        items = listing[:items]
        if items.empty?
          label = state || "recent"
          return %(<p class="empty">No #{h(label)} jobs#{" in #{h(queue)}" if queue}.</p>)
        end

        body = +""
        unless compact
          token = csrf_token(env)
          return_to = state || "all"
          body << %(<form id="bulk-jobs" method="post" action="#{html_url(route_path(:bulk_action,
                                                                                     action: :retry))}" data-bulk-form><input type="hidden" name="_csrf" value="#{h(token)}"><input type="hidden" name="return_to" value="#{h(return_to)}"><input type="hidden" name="queue" value="#{h(queue)}"><input type="hidden" name="page" value="#{h(listing[:page])}"><div class="bulk-bar"><span class="select-count">Bulk actions</span>)
          body << %(<button formaction="#{html_url(route_path(:bulk_action,
                                                              action: :retry))}" class="button"#{" disabled" unless state.nil? || state == "failed"}>Retry selected</button>)
          body << %(<button formaction="#{html_url(route_path(:bulk_action,
                                                              action: :run_now))}" class="button secondary"#{" disabled" unless state == "scheduled"}>Run now selected</button>)
          body << %(<button formaction="#{html_url(route_path(:bulk_action,
                                                              action: :delete))}" class="button danger" data-confirm="delete"#{" disabled" if state == "running"}>Delete selected</button></div></form>)
        end
        body << %(<div class="table-wrap"><table class="jobs-table"><thead><tr>)
        unless compact
          body << %(<th class="check-col"><input type="checkbox" id="select-all" aria-label="Select all jobs on this page"></th>)
        end
        body << %(<th>ID</th><th>Job</th><th>Queue</th><th>Arguments</th><th>Attempts</th><th>State</th><th>Run at / Enqueued at</th>)
        body << "<th>Error</th>" if state == "failed"
        body << "<th>Actions</th>" unless compact
        body << "</tr></thead><tbody>"
        items.each do |job|
          job_state = job[:state] || job_state(job)
          when_time = case job_state
                      when "scheduled" then job[:run_at]
                      when "completed" then job[:completed_at]
                      else job[:created_at]
                      end
          args_text = JSON.generate(job[:args])
          body << "<tr>"
          unless compact
            body << %(<td><input type="checkbox" name="ids[]" value="#{h(job[:id])}" form="bulk-jobs" aria-label="Select job #{h(job[:id])}"></td>)
          end
          body << %(<td><a class="job-id" href="#{html_url(route_path(:job, id: job[:id]))}">##{h(job[:id])}</a></td>)
          body << %(<td><a href="#{html_url(route_path(:job,
                                                       id: job[:id]))}">#{h(job[:job_class])}</a></td><td>#{h(job[:queue])}</td>)
          body << %(<td class="args-cell" title="#{h(args_text)}">#{h(truncate(args_text, 64))}</td>)
          body << %(<td>#{h(job[:attempts])}</td><td><span class="state state-#{h(job_state)}">#{h(job_state)}</span></td>)
          body << %(<td>#{relative_time(when_time)}</td>)
          error_class, error_message, = error_parts(job[:last_error])
          error_summary = if error_class.empty? && error_message.empty?
                            "No error details recorded"
                          else
                            "#{error_class}: #{error_message.empty? ? "No message" : error_message}"
                          end
          body << %(<td class="error-cell">#{h(truncate(error_summary, 72))}</td>) if state == "failed"
          unless compact
            body << %(<td class="row-actions">#{job_actions(job, job_state, env, state: state, queue: queue,
                                                                                 page: listing[:page])}</td>)
          end
          body << "</tr>"
        end
        body << "</tbody></table></div>"
        body
      end

      def job_actions(job, job_state_name, env, state: nil, queue: nil, page: nil, return_to: "list")
        token = csrf_token(env)
        params = { return_to: state || return_to, queue: queue, page: page }
        if job[:failed_at] || state == "failed"
          action_form(job[:id], "retry", "Retry", token, params: params) +
            action_form(job[:id], "delete", "Delete", token, destructive: true, params: params.merge(failed: true))
        elsif job_state_name == "scheduled"
          action_form(job[:id], "run-now", "Run now", token, params: params) +
            action_form(job[:id], "delete", "Delete", token, destructive: true, params: params)
        elsif %w[ready completed].include?(job_state_name)
          action_form(job[:id], "delete", "Delete", token, destructive: true, params: params)
        else
          "<span class=\"muted\">—</span>"
        end
      end

      def state_tabs(state, queue, counts)
        tabs = [[nil, "All", counts.values.sum], *%w[ready scheduled running failed completed].map do |key|
          [key, key.capitalize, counts[key]]
        end]
        %(<nav class="state-tabs" aria-label="Job state filter">#{tabs.map do |key, label, count|
          active = state == key ? " active" : ""
          %(<a class="state-tab#{active}" href="#{html_url(route_path(key ? key.to_sym : :all),
                                                           queue: queue)}">#{h(label)} <span>#{count}</span></a>)
        end.join}</nav>)
      end

      def queue_filter(state, queue, stats)
        options = %(<option value="">All queues</option>) + stats.keys.sort.map do |name|
          selected = queue == name ? " selected" : ""
          %(<option value="#{h(name)}"#{selected}>#{h(name)}</option>)
        end.join
        %(<form class="queue-filter" method="get" action="#{html_url(route_path(state ? state.to_sym : :all))}"><label for="queue">Queue</label><select id="queue" name="queue">#{options}</select><button class="button secondary">Apply</button></form>)
      end

      def state_counts(stats, queue: nil)
        queues = queue.nil? || queue.empty? ? stats.values : [stats.fetch(queue, {})]
        %w[ready scheduled running failed completed].to_h do |key|
          [key, queues.sum do |counts|
            counts[key.to_sym].to_i
          end]
        end
      end

      def pagination(listing, state:, queue:)
        total = listing[:total]
        per_page = listing[:per_page]
        page = listing[:page]
        pages = (total.to_f / per_page).ceil
        first = total.zero? ? 0 : ((page - 1) * per_page) + 1
        last = [page * per_page, total].min
        return %(<div class="pagination"><span class="page-summary">No jobs to show</span></div>) if total.zero?

        links = %(<span class="page-summary">Showing #{first}–#{last} of #{total}</span>)
        if pages > 1
          links << %(<nav class="page-links" aria-label="Job pages">)
          if page > 1
            links << %(<a class="page-link" href="#{html_url(route_path(state ? state.to_sym : :all), queue: queue,
                                                                                                      page: page - 1)}">Previous</a>)
          end
          page_window(pages, page).each do |number|
            if number == :ellipsis
              links << %(<span class="page-ellipsis">…</span>)
            else
              klass = number == page ? "page-link current" : "page-link"
              links << %(<a class="#{klass}" href="#{html_url(route_path(state ? state.to_sym : :all), queue: queue,
                                                                                                       page: number)}">#{number}</a>)
            end
          end
          if page < pages
            links << %(<a class="page-link" href="#{html_url(route_path(state ? state.to_sym : :all), queue: queue,
                                                                                                      page: page + 1)}">Next</a>)
          end
          links << "</nav>"
        end
        %(<div class="pagination">#{links}</div>)
      end

      def page_window(pages, current)
        visible = ([1, pages] + (([current - 2, 1].max)..([current + 2, pages].min)).to_a).uniq.sort
        visible.each_with_object([]) do |page, result|
          result << :ellipsis if result.any? && page - result.last > 1
          result << page
        end
      end

      def action_form(id, action, label, token, destructive: false, params: {})
        query = { return_to: params[:return_to], queue: params[:queue], page: params[:page],
                  failed: action == "delete" && (params[:state] == "failed" || params[:failed]) ? 1 : nil }
        route_action = { "run-now" => :run_now, "discard" => :delete }.fetch(action, action.to_sym)
        target = html_url(route_path(:job_action, id: id, action: route_action), **query.except(:state))
        klass = destructive ? "button danger small" : "button small"
        confirm = destructive ? %( data-confirm="Delete this job?") : ""
        %(<form class="inline-form" method="post" action="#{target}"#{confirm}><input type="hidden" name="_csrf" value="#{h(token)}"><button class="#{klass}">#{h(label)}</button></form>)
      end

      def notice(value)
        return "" unless value

        messages = { "retried" => "Job queued for another attempt.", "discarded" => "Failed job deleted.",
                     "run-now" => "Job scheduled to run now.", "delete" => "Job deleted." }
        text = messages[value] || (value =~ /\Abulk-(retry|delete|run-now)-(\d+)\z/ && "#{::Regexp.last_match(2)} job(s) updated.")
        text ? %(<p class="notice" role="status">#{h(text)}</p>) : ""
      end

      def action_notice(action)
        { "retry" => "retried", "discard" => "discarded", "run-now" => "run-now", "run_now" => "run-now",
          "delete" => "delete" }.fetch(action)
      end

      def error_parts(error)
        return ["", "", ""] if error.nil? || error.empty?

        first, *trace = error.lines
        klass, message = first.to_s.chomp.split(/:\s*/, 2)
        [klass || "Error", message || first.to_s.chomp, trace.join]
      end

      def truncate(value, length)
        text = value.to_s
        text.length > length ? "#{text[0, length - 1]}…" : text
      end

      def relative_time(value)
        return "—" unless value

        time = value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
        delta = (Time.now - time).to_i
        phrase = if delta.abs < 60
                   "#{delta.abs} seconds"
                 elsif delta.abs < 3600
                   "#{delta.abs / 60} minutes"
                 elsif delta.abs < 86_400
                   "#{delta.abs / 3600} hours"
                 else
                   "#{delta.abs / 86_400} days"
                 end
        title = time.iso8601
        %(<time datetime="#{h(title)}" title="#{h(title)}">#{h(delta.negative? ? "in #{phrase}" : "#{phrase} ago")}</time>)
      rescue ArgumentError
        h(value)
      end

      def detail_value(value) = value.respond_to?(:to_time) ? relative_time(value) : h(value || "—")

      def parse_form(env)
        return {} unless env["CONTENT_TYPE"].to_s.split(";").first == "application/x-www-form-urlencoded"

        length = env["CONTENT_LENGTH"].to_s
        raise ArgumentError, "Form is too large" if length.match?(/\A\d+\z/) && length.to_i > FORM_LIMIT

        input = env[Rack::RACK_INPUT]
        raw = input ? input.read(FORM_LIMIT + 1).to_s : ""
        raise ArgumentError, "Form is too large" if raw.bytesize > FORM_LIMIT

        Rack::Utils.parse_nested_query(raw)
      end

      def csrf_token(env)
        nonce = env["gemstack.jobs_dashboard.csrf_nonce"] || Rack::Request.new(env).cookies[COOKIE]
        nonce = nil unless nonce&.match?(/\A[a-f0-9]{64}\z/)
        if nonce.nil?
          nonce = SecureRandom.hex(32)
          env["gemstack.jobs_dashboard.csrf_nonce"] = nonce
        end
        OpenSSL::HMAC.hexdigest("SHA256", GemStack.key_for("jobs_dashboard_csrf"), nonce)
      end

      def valid_csrf?(env, submitted)
        nonce = Rack::Request.new(env).cookies[COOKIE]
        unless nonce&.match?(/\A[a-f0-9]{64}\z/) && submitted.is_a?(String) && submitted.match?(/\A[a-f0-9]{64}\z/)
          return false
        end

        expected = OpenSSL::HMAC.hexdigest("SHA256", GemStack.key_for("jobs_dashboard_csrf"), nonce)
        OpenSSL.fixed_length_secure_compare(expected, submitted)
      end

      def html(content, env:, active:)
        csrf_token(env)
        headers = {}
        if (nonce = env.delete("gemstack.jobs_dashboard.csrf_nonce"))
          cookie_path = @config.path
          https = env[Rack::RACK_URL_SCHEME] == "https" || env["HTTP_X_FORWARDED_PROTO"]&.start_with?("https")
          secure = https ? "; Secure" : ""
          headers["set-cookie"] = "#{COOKIE}=#{nonce}; Path=#{cookie_path}; HttpOnly; SameSite=Strict#{secure}"
        end
        script_hash = [OpenSSL::Digest::SHA256.digest(dashboard_script)].pack("m0")
        headers["content-security-policy"] =
          "default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-#{script_hash}'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
        page = <<~HTML
          <!doctype html>
          <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{h(GemStack.config.name)} · Jobs</title><style>#{styles}</style></head>
          <body><header class="topbar"><a class="brand" href="#{html_url(route_path(:overview))}">GemStack Jobs</a>#{top_navigation(active)}</header>
          <main>#{content}</main><footer>GemStack background jobs</footer>
          <script>#{dashboard_script}</script></body></html>
        HTML
        [200, response_headers(headers), [page]]
      end

      def top_navigation(active)
        counts = state_counts(@dashboard.stats)
        tabs = [[:overview, "Overview", nil], *%w[ready scheduled running failed completed].map do |state|
          [state.to_sym, state.capitalize, state]
        end]
        %(<nav class="topnav">#{tabs.map do |route, label, state|
          selected = (route == :overview && active == :overview) || state == active ? " active" : ""
          total = state ? counts[state] : counts.values.sum
          count = %(<span class="count-badge">#{total}</span>)
          %(<a class="top-tab#{selected}" href="#{html_url(route_path(route))}">#{h(label)}#{count}</a>)
        end.join}</nav>)
      end

      def dashboard_script
        <<~JS.strip
          document.getElementById('select-all')?.addEventListener('change', event => {
            document.querySelectorAll('input[name="ids[]"]').forEach(box => { box.checked = event.target.checked; });
          });
          document.querySelectorAll('form[data-confirm]').forEach(form => {
            form.addEventListener('submit', event => { if (!confirm(form.dataset.confirm)) event.preventDefault(); });
          });
          document.querySelector('[data-bulk-form]')?.addEventListener('submit', event => {
            if (event.submitter?.dataset.confirm && !confirm('Delete the selected jobs?')) event.preventDefault();
          });
        JS
      end

      def response(status, message, extra = {}, details: nil)
        details_html = details ? %(<pre class="code">#{h(details)}</pre>) : ""
        body = %(<main><h1>#{h(status)}</h1><p>#{h(message)}</p>#{details_html}<p><a href="#{html_url(route_path(:overview))}">Back to jobs</a></p></main>)
        page = "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>Jobs</title>#{body}</html>"
        [status, response_headers(extra), [page]]
      end

      def redirect(location, status: 303)
        [status, response_headers("location" => location), []]
      end

      def response_headers(extra = {})
        { "content-type" => "text/html; charset=utf-8", "content-length" => nil,
          "cache-control" => "no-store", "x-content-type-options" => "nosniff",
          "x-frame-options" => "DENY", "referrer-policy" => "no-referrer",
          "content-security-policy" => "default-src 'none'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'" }
          .merge(extra).compact
      end

      def request_path(env)
        path = env[Rack::PATH_INFO].to_s
        base = @config.path
        return "/" if path == base || path == "#{base}/"
        return path.delete_prefix(base) if path.start_with?("#{base}/")
        return path.empty? ? "/" : path if env[Rack::SCRIPT_NAME].to_s.end_with?(base)

        nil
      end

      def path_url(suffix, **query)
        base = @config.path
        url = suffix == "/" ? base : "#{base}#{suffix}"
        values = query.reject { |_key, value| value.nil? || value.to_s.empty? }
        values.empty? ? url : "#{url}?#{Rack::Utils.build_query(values)}"
      end

      def route_path(route, id: nil, action: nil)
        case route.to_sym
        when :overview then "/"
        when :all then "/all"
        when :ready, :scheduled, :running, :failed, :completed then "/#{route}"
        when :job then "/#{Integer(id)}"
        when :job_action then "/#{Integer(id)}/#{action}"
        when :bulk_action then "/bulk/#{action}"
        else raise ArgumentError, "Unknown jobs dashboard route"
        end
      end

      def route_url(route, id: nil, action: nil, **query)
        path_url(route_path(route, id: id, action: action), **query)
      end

      def legacy_jobs_redirect(request)
        query = request.GET.to_h.transform_keys(&:to_sym)
        state = query.delete(:state)
        route = %w[ready scheduled running failed completed].include?(state) ? state.to_sym : :all
        redirect(route_url(route, **query), status: 301)
      end

      def html_url(suffix, **query) = h(path_url(suffix, **query))

      def job_state(job)
        return "failed" if job[:failed_at]
        return "completed" if job[:completed_at]
        return "running" if job[:locked_at]
        return "scheduled" if job[:run_at] > Time.now

        "ready"
      end

      def h(value) = CGI.escapeHTML(value.to_s)

      def database_connection_error?(error)
        return false unless defined?(Sequel::DatabaseConnectionError)

        error_chain(error).any? do |item|
          item.is_a?(Sequel::DatabaseConnectionError) ||
            (defined?(Sequel::PoolTimeout) && item.is_a?(Sequel::PoolTimeout))
        end
      end

      def missing_jobs_table_error?(error)
        return false unless defined?(Sequel::DatabaseError)
        return false unless error_chain(error).any?(Sequel::DatabaseError)

        table = Jobs.config.table.to_s.downcase
        error_chain(error).any? do |item|
          message = item.message.to_s.downcase
          message.include?(table) &&
            message.match?(/no such table|undefined table|relation .+ does not exist|table .+ doesn.t exist/)
        end
      end

      def error_chain(error)
        chain = []
        while error && !chain.include?(error)
          chain << error
          error = error.cause
        end
        chain
      end

      def log_exception(message, error)
        GemStack.logger.error(message, error_class: error.class.name, error_message: error.message,
                                       backtrace: Array(error.backtrace))
      end

      def styles
        <<~CSS
          :root{color-scheme:light;--ink:#17211d;--muted:#6b7771;--line:#e0e7e3;--paper:#f4f7f5;--green:#18794e;--red:#b42318;--blue:#dcecff;--amber:#fff0cc;--purple:#eee8fb}
          *{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:14px/1.5 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}a{color:var(--green);text-decoration:none}a:hover{text-decoration:underline}
          .topbar{position:sticky;top:0;z-index:5;background:#fff;border-bottom:1px solid var(--line);display:flex;align-items:center;justify-content:space-between;padding:0 max(24px,calc((100% - 1280px)/2));min-height:64px;gap:30px}.brand{font-weight:750;color:var(--ink);font-size:16px;white-space:nowrap}.topnav,.state-tabs{display:flex;align-items:center;gap:4px;overflow-x:auto}.top-tab{padding:20px 13px;color:var(--muted);border-bottom:3px solid transparent;white-space:nowrap}.top-tab.active{color:var(--green);border-color:var(--green);font-weight:650}.count-badge,.state-tab span{margin-left:5px;background:#edf2ef;color:#57645d;border-radius:99px;padding:2px 7px;font-size:11px;font-weight:650}
          main{max-width:1280px;margin:30px auto;padding:0 24px}.page-heading,.section-heading{display:flex;align-items:center;justify-content:space-between;gap:16px;margin-bottom:18px}.page-heading h1,.section-heading h2{margin:0;letter-spacing:-.025em}.page-heading h1{font-size:29px}.eyebrow{margin:0 0 4px;color:var(--muted);text-transform:uppercase;font-size:10px;letter-spacing:.12em;font-weight:700}.section-heading h2{font-size:19px}.text-link{font-weight:600}.panel,.summary-card{background:#fff;border:1px solid var(--line);border-radius:12px;box-shadow:0 2px 7px #17211d08}.panel{padding:20px;margin:20px 0}.summary-grid{display:grid;grid-template-columns:repeat(5,minmax(120px,1fr));gap:14px}.summary-card{padding:18px 20px;color:var(--ink);display:flex;flex-direction:column;gap:6px}.summary-card span{color:var(--muted);font-weight:600}.summary-card strong{font-size:32px;line-height:1.15;letter-spacing:-.04em}.summary-card:hover{border-color:#8bb99f;text-decoration:none;transform:translateY(-1px)}
          .state-tabs{border-bottom:1px solid var(--line);margin:4px 0 16px}.state-tab{color:var(--muted);padding:11px 14px;border-bottom:2px solid transparent;white-space:nowrap}.state-tab.active{color:var(--green);border-color:var(--green);font-weight:700}.state-tab.active span{background:#e4f3e9;color:var(--green)}.queue-filter{display:flex;align-items:center;gap:9px;margin:12px 0 18px}.queue-filter label{font-weight:600}.queue-filter select{min-width:170px}.queue-filter select,.filters input{border:1px solid var(--line);border-radius:7px;padding:8px 10px;background:white;color:var(--ink)}
          .table-wrap{overflow:auto;border:1px solid var(--line);border-radius:10px;background:white}table{width:100%;border-collapse:collapse;text-align:left;white-space:nowrap}th,td{padding:11px 12px;border-bottom:1px solid #edf1ee;vertical-align:middle}thead{background:#f8faf8;color:#67736d;font-size:10px;text-transform:uppercase;letter-spacing:.07em}tbody tr:hover{background:#fafcfb}tbody tr:last-child>*{border-bottom:0}.jobs-table{min-width:1000px}.jobs-table td.args-cell,.jobs-table td.error-cell{max-width:220px;overflow:hidden;text-overflow:ellipsis}.check-col{width:48px}.job-id{font-variant-numeric:tabular-nums;color:var(--muted)}input[type=checkbox]{accent-color:var(--green);width:15px;height:15px;vertical-align:middle}.state{display:inline-block;border-radius:99px;padding:3px 9px;font-size:11px;font-weight:700;text-transform:capitalize;background:#e7f0ff;color:#24558d}.state-scheduled{background:var(--purple);color:#65459a}.state-running{background:var(--amber);color:#805500}.state-failed{background:#fde7e5;color:#a52b24}
          .bulk-bar,.pagination,.row-actions{display:flex;align-items:center;gap:7px;flex-wrap:wrap}.bulk-bar{margin:0 0 12px}.select-count{display:flex;align-items:center;gap:7px;color:var(--muted);margin-right:auto}.inline-form{display:inline-flex;margin:0}.button{border:0;border-radius:7px;background:var(--green);color:white;padding:8px 12px;font:600 12px/1.2 system-ui,sans-serif;cursor:pointer;display:inline-block}.button:hover{text-decoration:none;filter:brightness(.95)}.button:disabled{opacity:.45;cursor:not-allowed}.button.secondary{background:#e9efeb;color:var(--ink)}.button.danger{background:var(--red);color:white}.button.small{padding:6px 9px;font-size:11px}.empty,.notice{padding:18px;background:#fff;border:1px solid var(--line);border-radius:10px;color:var(--muted)}.notice{border-color:#abd0b8;background:#eef8f1;color:#245d39;margin:14px 0}.pagination{justify-content:space-between;margin:15px 0;color:var(--muted)}.page-links{display:flex;gap:5px;align-items:center}.page-link{padding:6px 9px;border:1px solid var(--line);border-radius:6px;background:#fff;color:var(--ink)}.page-link.current{background:var(--green);border-color:var(--green);color:white}.page-ellipsis{padding:0 3px}
          .details{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px;border-top:1px solid var(--line);padding:18px 0}.details dt{color:var(--muted);font-size:12px}.details dd{margin:3px 0 0;font-weight:600;overflow-wrap:anywhere}.code{overflow:auto;background:#18231e;color:#e7efe9;border-radius:9px;padding:16px;white-space:pre-wrap;overflow-wrap:anywhere;max-height:360px}.trace{white-space:pre;overflow:auto}.error-card{background:#fff4f2;border:1px solid #f2c7c2;border-radius:8px;padding:12px 14px}.error-card p{margin:4px 0 0}.breadcrumbs{color:var(--muted);margin:0 0 12px}.detail-panel{padding:24px}.detail-actions{margin-top:16px}.muted{color:var(--muted)}footer{text-align:center;color:var(--muted);padding:28px}
          @media(max-width:850px){.topbar{align-items:flex-start;flex-direction:column;gap:0;padding:10px 16px 0}.topnav{max-width:100%;width:100%}.top-tab{padding:12px 9px}.summary-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.summary-card.total{grid-column:span 2}.details{grid-template-columns:repeat(2,minmax(0,1fr))}main{padding:0 16px;margin:22px auto}.panel{padding:15px}}
          @media(max-width:480px){.summary-grid{grid-template-columns:1fr 1fr;gap:8px}.summary-card{padding:14px}.summary-card strong{font-size:26px}.details{grid-template-columns:1fr}.page-heading h1{font-size:24px}.pagination{align-items:flex-start;flex-direction:column}.queue-filter{flex-wrap:wrap}}
        CSS
      end
      # rubocop:enable Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength, Layout/LineLength, Lint/DuplicateBranch, Style/StringConcatenation
    end
  end
end
