# frozen_string_literal: true

require_relative "../config/app"
require "fileutils"

GemStack.boot!
GemStack.application.eager_load!

USAGE = "Usage: bundle exec ruby script/jobs_demo.rb enqueue " \
        "{success|fail|flaky|slow|scheduled|args|queue-a|queue-b|many [count]}"

adapter = GemStack::Jobs::Adapters::Database.new
command, *args = ARGV

case command
when "enqueue"
  name = args.shift
  job = {
    "success" => -> { DemoJobs::SuccessJob.perform_later("hello from SuccessJob") },
    "fail" => -> { DemoJobs::FailJob.perform_later },
    "flaky" => lambda {
      FileUtils.rm_f(File.join(GemStack.root, "tmp", "gemstack-flaky-job-ran"))
      DemoJobs::FlakyJob.perform_later
    },
    "slow" => -> { DemoJobs::SlowJob.perform_later },
    "scheduled" => -> { DemoJobs::ScheduledJob.set(wait: 180).perform_later("scheduled demo") },
    "args" => -> { DemoJobs::ArgsJob.perform_later("hello", 42, { greeting: "hi", count: 3 }) },
    "queue-a" => -> { DemoJobs::SuccessJob.set(queue: "smoke-a").perform_later("queue A") },
    "queue-b" => -> { DemoJobs::SuccessJob.set(queue: "smoke-b").perform_later("queue B") }
  }
  if name == "many"
    count = Integer(args.fetch(0, "60"))
    abort "Choose a number from 1 to 100." unless count.between?(1, 100)
    count.times { |i| DemoJobs::SuccessJob.perform_later("page demo #{i + 1}") }
    puts "Enqueued #{count} SuccessJob jobs."
  elsif job.key?(name)
    id = job.fetch(name).call
    puts "Enqueued #{name} job ##{id}."
  else
    abort USAGE
  end
when "reset"
  running = adapter.stats.values.sum { |counts| counts[:running].to_i }
  abort "A job is running. Wait for it to finish, then run reset again." if running.positive?

  count = adapter.db[GemStack.config.jobs.table].delete
  FileUtils.rm_f(File.join(GemStack.root, "tmp", "gemstack-flaky-job-ran"))
  puts "Deleted #{count} queued, scheduled, and failed job(s)."
else
  abort "#{USAGE} | reset"
end
