# frozen_string_literal: true

source "https://rubygems.org"

# Every GemStack gem is developed in this monorepo.
path "gems" do
  gem "gemstack"
  gem "gemstack-auth"
  gem "gemstack-cli"
  gem "gemstack-realtime"
end

group :development, :test do
  gem "argon2", "~> 2.3" # gemstack-auth password hashing (apps get it via gemstack-auth)
  gem "aws-sdk-s3", "~> 1.232" # optional in apps (storage :s3 service); tested with stubbed responses
  gem "bcrypt", "~> 3.1" # verifying legacy bcrypt hashes; tested here
  gem "benchmark" # a bundled (not default) gem since Ruby 4.0
  gem "brotli", "~> 0.8" # optional in apps; tested here
  gem "minitest", "~> 5.25"
  gem "mysql2", "~> 0.5" # database drivers: tested against every supported adapter
  gem "oj", "~> 3.16"
  gem "pg", "~> 1.5"
  gem "rack-test", "~> 2.2"
  gem "rake", "~> 13.0"
  gem "redis-client", "~> 0.25" # optional in apps (cache :redis store); tested here
  gem "rubocop", "~> 1.81", require: false
  gem "sidekiq", "~> 8.1" # optional in apps (jobs :sidekiq adapter); tested here
  gem "sqlite3", "~> 2.0"
  gem "trilogy", "~> 2.9"
end
