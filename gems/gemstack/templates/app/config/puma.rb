# frozen_string_literal: true

# Puma configuration. Every value can be set through the environment.
# `gemstack dev` sets GEMSTACK_API_HOST/PORT to a private loopback port
# behind the development gateway.

max_threads = Integer(ENV.fetch("GEMSTACK_MAX_THREADS", 5))
min_threads = Integer(ENV.fetch("GEMSTACK_MIN_THREADS", max_threads))
threads min_threads, max_threads

bind "tcp://#{ENV.fetch("GEMSTACK_API_HOST", "0.0.0.0")}:#{ENV.fetch("GEMSTACK_API_PORT", 4000)}"
environment ENV.fetch("GEMSTACK_ENV", "development")

# Cluster mode for multi-core production servers: WEB_CONCURRENCY=4
worker_count = Integer(ENV.fetch("WEB_CONCURRENCY", 0))
if worker_count.positive?
  workers worker_count
  preload_app!
  # Connections must not be shared across forked workers; each reconnects lazily.
  before_fork { GemStack::DB.disconnect if defined?(GemStack::DB) }
end
