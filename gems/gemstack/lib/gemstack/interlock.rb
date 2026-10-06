# frozen_string_literal: true

module GemStack
  # A readers/writer lock. Requests hold a shared lock while application code
  # runs; code reloading takes the exclusive lock, so a reload never happens
  # while another thread is executing code that is about to be unloaded.
  class Interlock
    def initialize
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @readers = 0
      @writer = false
      @waiting_writers = 0
    end

    def acquire_shared
      @mutex.synchronize do
        # Waiting writers get priority so a busy server can't starve a reload.
        @condition.wait(@mutex) while @writer || @waiting_writers.positive?
        @readers += 1
      end
    end

    def release_shared
      @mutex.synchronize do
        @readers -= 1
        @condition.broadcast if @readers.zero?
      end
    end

    # Runs application code outside a request (e.g. realtime handlers).
    def shared
      acquire_shared
      yield
    ensure
      release_shared
    end

    def exclusive
      @mutex.synchronize do
        @waiting_writers += 1
        @condition.wait(@mutex) while @writer || @readers.positive?
        @waiting_writers -= 1
        @writer = true
      end
      yield
    ensure
      @mutex.synchronize do
        @writer = false
        @condition.broadcast
      end
    end
  end
end
