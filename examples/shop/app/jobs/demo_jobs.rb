# frozen_string_literal: true

# Jobs used by docs/jobs_smoke_test.md. Load with script/jobs_demo.rb.
module DemoJobs
  class SuccessJob < ApplicationJob
    def perform(*args)
      puts "SuccessJob finished: #{args.inspect}"
    end
  end

  class FailJob < ApplicationJob
    retry_on StandardError, attempts: 1

    def perform
      raise "GemStack smoke test failure (expected)"
    end
  end

  class FlakyJob < ApplicationJob
    retry_on StandardError, attempts: 2, wait: 1

    def perform
      marker = File.join(GemStack.root, "tmp", "gemstack-flaky-job-ran")
      FileUtils.mkdir_p(File.dirname(marker))
      unless File.exist?(marker)
        File.write(marker, "failed once")
        raise "GemStack smoke test: first attempt fails"
      end

      puts "FlakyJob succeeded on retry"
    end
  end

  class SlowJob < ApplicationJob
    def perform
      puts "SlowJob started; sleeping for 60 seconds"
      sleep 60
      puts "SlowJob finished"
    end
  end

  class ScheduledJob < ApplicationJob
    def perform(*args)
      puts "ScheduledJob finished: #{args.inspect}"
    end
  end

  class ArgsJob < ApplicationJob
    def perform(*args)
      puts "ArgsJob received: #{args.inspect}"
    end
  end
end
