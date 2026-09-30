# frozen_string_literal: true

module GemStack
  module Dev
    # A child process whose output is streamed, line by line, to a Terminal.
    # Each child runs in its own process group so stopping it also stops
    # anything it spawned (e.g. npm → node).
    class ManagedProcess
      attr_reader :name, :command, :pid, :status

      def initialize(name, command, terminal:, env: {}, chdir: Dir.pwd)
        @name = name
        @command = Array(command)
        @terminal = terminal
        @env = env
        @chdir = chdir.to_s
        @pid = nil
        @status = nil
      end

      def start
        reader, writer = IO.pipe
        @status = nil
        @pid = Process.spawn(@env, *@command, chdir: @chdir, out: writer, err: writer, in: File::NULL,
                                              pgroup: true)
        writer.close
        @output = Thread.new do
          reader.each_line { |line| @terminal.line(@name, line) }
        rescue IOError
          nil
        ensure
          reader.close
        end
        self
      rescue SystemCallError => e
        writer&.close
        reader&.close
        @terminal.line(@name, "could not start `#{@command.join(" ")}`: #{e.message}")
        @status = :failed_to_start
        self
      end

      # Non-blocking. Records the exit status once the process has exited.
      def running?
        return false unless @pid
        return false if @status

        done = Process.waitpid2(@pid, Process::WNOHANG)
        return true unless done

        @status = done[1]
        false
      rescue Errno::ECHILD
        @status ||= :unknown
        false
      end

      def exited? = !@status.nil?

      def stop(timeout: 5)
        return unless running?

        signal("TERM")
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        sleep 0.05 while running? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        signal("KILL") if running?
        running?
        @output&.join(1)
      end

      def restart
        stop
        start
      end

      def describe_status
        case @status
        when Process::Status then @status.signaled? ? "signal #{@status.termsig}" : "status #{@status.exitstatus}"
        else @status.to_s
        end
      end

      private

      def signal(name)
        Process.kill(name, -@pid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill(name, @pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
    end
  end
end
