# frozen_string_literal: true

require "gemstack/core"

module GemStack
  # Development tooling: the single-origin gateway and the process
  # supervisor behind `gemstack dev` (ARCHITECTURE §5). Nothing here is
  # loaded in production unless explicitly required.
  module Dev
    autoload :FileWatcher, "gemstack/dev/file_watcher"
    autoload :Gateway, "gemstack/dev/gateway"
    autoload :ManagedProcess, "gemstack/dev/managed_process"
    autoload :Ports, "gemstack/dev/ports"
    autoload :Supervisor, "gemstack/dev/supervisor"
    autoload :Terminal, "gemstack/dev/terminal"
    autoload :Toolchain, "gemstack/dev/toolchain"

    class Config < Settings
      # The single public port.
      setting :port, default: -> { Integer(ENV.fetch("PORT", 3000)) }
      # Interfaces the gateway listens on. Both loopback families, because
      # browsers may resolve "localhost" to either.
      setting :bind, default: %w[127.0.0.1 ::1]
      setting :frontend_dir, default: "frontend"
      setting :api_command, default: %w[bundle exec puma -C config/puma.rb]
      # nil = run the frontend's own `next` binary in dev mode.
      setting :frontend_command, default: nil
      # Changes here restart the Ruby process. app/ and config/routes.rb are
      # reloaded in-process instead and don't need a restart.
      setting :restart_on, default: ["config/**/*.rb", "Gemfile.lock", ".env*"]
      setting :restart_exclude, default: ["config/routes.rb"]
      # Regenerates TypeScript types/clients when backend code changes
      # (only when the app has a frontend). nil disables.
      setting :contract_command, default: %w[bundle exec gemstack contract --quiet]
      setting :contract_watch, default: ["app/**/*.rb", "config/routes.rb"]
      # Background job worker, run when the app uses the :postgres job
      # adapter and has the gemstack_jobs migration. Restarted when app/ changes.
      setting :jobs_command, default: %w[bundle exec gemstack jobs]
    end
  end

  Config.namespace(:dev, Dev::Config)
end
