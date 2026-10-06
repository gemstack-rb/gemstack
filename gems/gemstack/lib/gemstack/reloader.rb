# frozen_string_literal: true

require "gemstack/dev/file_watcher"

module GemStack
  # Development middleware: reloads application code and routes before a
  # request when files under app/ or config/routes.rb have changed.
  # The shared lock is held until the response body is
  # closed, so streamed responses finish on the code that produced them.
  class Reloader
    WATCHED = ["app/**/*", "config/routes.rb"].freeze

    def initialize(app, application)
      @app = app
      @application = application
      @watcher = Dev::FileWatcher.new(WATCHED, root: application.root)
      @interlock = application.interlock
      @check = Mutex.new
    end

    def call(env)
      reload_if_changed
      @interlock.acquire_shared
      begin
        status, headers, body = @app.call(env)
      rescue Exception # rubocop:disable Lint/RescueException -- release the lock, then re-raise anything
        @interlock.release_shared
        raise
      end
      [status, headers, Rack::BodyProxy.new(body) { @interlock.release_shared }]
    end

    private

    def reload_if_changed
      changed = @check.synchronize { @watcher.changed? }
      return unless changed

      @interlock.exclusive { @application.reload! }
    end
  end
end
