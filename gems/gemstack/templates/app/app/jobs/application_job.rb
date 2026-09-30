# frozen_string_literal: true

# The base class for this app's background jobs (docs/background-jobs.md):
# retry and discard rules declared here apply to every job.
class ApplicationJob < GemStack::Job
  # retry_on Net::ReadTimeout, attempts: 5, wait: 30   # seconds, :exponential or ->(attempt) { … }
  # discard_on GemStack::NotFound                      # e.g. the record was deleted before the job ran
  # queue :default
end
