# Background jobs

GemStack jobs run in **the app's own database** by default (SQLite, PostgreSQL or MySQL) — no Redis, no extra service.
Work only becomes asynchronous when you ask for it with
`perform_later`.

## Writing a job

```bash
gemstack generate job SendWelcomeEmail mailers
gemstack db:migrate          # the first job adds the gemstack_jobs table
```

```ruby
# app/jobs/send_welcome_email.rb
class SendWelcomeEmail < ApplicationJob
  queue :mailers                                     # default: "default"
  priority 10                                        # lower runs first; default 100
  retry_on Net::ReadTimeout, attempts: 5, wait: 30   # seconds, :exponential, or ->(attempt) { … }
  discard_on GemStack::NotFound                      # drop instead of retrying

  def perform(user_id)
    user = User.find(user_id)
    Mailer.welcome(user).deliver
  end
end
```

```ruby
SendWelcomeEmail.perform_later(user.id)                   # => job id
SendWelcomeEmail.set(wait: 600).perform_later(user.id)    # in 10 minutes
SendWelcomeEmail.set(at: tomorrow_9am).perform_later(user.id)
SendWelcomeEmail.set(queue: :urgent, priority: 1).perform_later(user.id)
SendWelcomeEmail.perform_now(user.id)                     # synchronously
```

**Arguments** must be JSON values: strings, numbers, booleans, nil, arrays and
hashes. Pass ids, not records — records may have changed by the time the job
runs. Passing anything else raises when you enqueue, not later in the worker.
Hash keys arrive as strings.

**Delivery is at-least-once.** If a worker dies mid-job, the job runs again
after `config.jobs.lock_timeout`. Make `perform` safe to repeat (idempotent).

## Transactions

Enqueueing inserts a row on the same connection, so a job enqueued inside a
transaction exists only if the transaction commits:

```ruby
order = GemStack.transaction do
  Order.create(input).tap { |created| SendReceipt.perform_later(created.id) }
end
```

If the order fails to save, no receipt job is ever created. On PostgreSQL,
workers are woken by `NOTIFY`, which is also transactional, so the job starts
within milliseconds of the commit; on MySQL and SQLite they poll every second
(`config.jobs.poll_interval`). Workers claim jobs with `FOR UPDATE SKIP LOCKED`
on PostgreSQL and MySQL 8, and with SQLite's write lock on SQLite, so a job is
never run by two workers at once. (The `:async` and
`:sidekiq` adapters wait for the commit too.)

## Retries and failures

| Situation | What happens |
|---|---|
| any `StandardError` (default) | retried up to 10 attempts with exponential backoff (16s, 31s, 96s, … ≈ 4 hours in total) |
| `retry_on X, attempts:, wait:` | your policy for X (the most recently declared matching rule wins) |
| `discard_on X` | dropped and logged, never retried |
| attempts exhausted | kept as **failed** (`failed_at`, `last_error`) for inspection |
| success | kept in **completed** history (`completed_at`) until deleted |
| unknown job class | failed immediately |

```bash
gemstack jobs:status            # ready / scheduled / running / failed / completed per queue
gemstack jobs:failed            # recent failures with their errors
gemstack jobs:retry [IDS…]      # back on the queue (all failed jobs without ids)
gemstack jobs:discard [IDS…]    # delete failed jobs
```

## Running workers

```bash
gemstack jobs                              # all queues, 5 threads
gemstack jobs -q mailers,default -c 10     # specific queues, 10 threads
```

- In development, **`gemstack dev` runs a worker for you** and restarts it when
  `app/` changes. Every app with a database gets the jobs table from `gemstack
  new` (apps created before that get it with their first `gemstack g job`).
  Jobs still only run in the background when you call `perform_later`.
- Workers claim jobs with `FOR UPDATE SKIP LOCKED`, so any number of worker
  processes can share a queue without ever running the same job twice at once.
- `SIGTERM`/`SIGINT` let running jobs finish for `shutdown_timeout` (25 s), then
  put unfinished jobs back on the queue.
- Each worker needs `concurrency + 2` database connections; the command sizes
  the pool automatically.

## Jobs dashboard

Apps that load `gemstack/jobs` expose the built-in operations UI at `/jobs` by
default. It shows queue counts, paginated jobs, job arguments, errors, and
completed-job history, and offers retry/discard actions for failed jobs.
Successful jobs remain in Completed until deleted. The dashboard reads persisted
rows through the database adapter; it does not inspect Sidekiq, in-process
`:async` jobs, `:inline` jobs or the `:test` adapter. Requests to `/jobs` with
another adapter receive an unavailable response. The `gemstack dev` gateway
sends the dashboard path to Ruby as well as the API path.

The dashboard requires the `gemstack_jobs` table. New database-backed apps get
its migration from `gemstack new`, and the development worker starts after the
migration is present. Existing apps need the migration too; see
[upgrading an existing app](#upgrading-an-existing-app).

### Authorization and security

The dashboard can reveal serialized arguments, exception messages and
backtraces, and its forms can change queue state. In development and test it is
open by default for local use. In production and other non-local environments,
it returns 404 unless an authorization callback is configured.
`gemstack doctor --production` reports when the dashboard is enabled without a
callback.

Set `config.jobs.dashboard.authorization` to a callable that receives the Rack
environment and returns **exactly `true`** for an authorized administrator:

```ruby
# config/app.rb
GemStack.configure do |config|
  config.jobs.dashboard.authorization = ->(env) { AdminAuthorization.allowed?(env) }
end
```

Implement `AdminAuthorization.allowed?` using the app's actual administrator
session, identity provider or network policy. A callback's presence is not an
authorization policy by itself. Any return value other than `true`, and any
exception raised by the callback, denies access. The denial is a 404 so the
endpoint does not reveal itself. The callback runs for every page and every
mutation. The production dashboard also needs the app's stable
`SECRET_KEY_BASE`; `gemstack doctor --production` checks it.

Retry and discard are POST forms protected by a CSRF token tied to an
HttpOnly, SameSite cookie and `SECRET_KEY_BASE`. Only a row still marked failed
can be changed by either action. Responses use `Cache-Control: no-store`,
restrictive content security policy and HTML escaping for job data.

To disable the UI, set:

```ruby
config.jobs.dashboard.enabled = false
```

To move it, set an absolute path without a trailing slash:

```ruby
config.jobs.dashboard.path = "/internal/jobs"
```

The path is outside `config.http.api_path`; it must not overlap the API path or
the health check path. `gemstack dev` sends the configured path to Ruby. In
production, route that path to the Ruby API process through the reverse proxy;
do not send it to the frontend. The generated Kamal config currently routes
`/api` to Ruby, so customize its proxy routes when exposing `/jobs`. A Next.js
`GEMSTACK_API_URL` rewrite proxies `/api/*` only and does not carry `/jobs`.

### Upgrading an existing app

For an app using released GemStack gems, run `gemstack update`. It updates the
GemStack gems and reconciles generated files, including `config/app.rb`, while
preserving or reporting local edits. Review its output: if your customized
`config/app.rb` is reported as a conflict, merge the new settings and make
sure it still contains `require "gemstack/jobs"`.

Template reconciliation deliberately does not create or apply migrations.
Install or update the jobs migrations, then apply them:

```bash
gemstack jobs:install
gemstack db:migrate
```

Then verify with `gemstack doctor`. If the database is unavailable or the
migration fails, fix the connection and rerun `gemstack db:migrate`; the
dashboard reports that the database/jobs migration is unavailable until the
table exists. Apps without a database cannot use this dashboard until they
configure a database adapter. For a GemStack `path` checkout, `gemstack update`
does not fetch or replace the checkout: update the checkout as the command
instructs, then apply the template and migration steps supported by that
checkout.

## Adapters

| Adapter | Default | Notes |
|---|---|---|
| `:database` (alias `:postgres`) | with `gemstack/db` loaded | durable, transactional, needs `gemstack jobs` processes |
| `:test` | in tests | records jobs; see below |
| `:async` | without a database | in-process threads; jobs are lost on restart — development only |
| `:inline` | — | runs immediately in the caller and raises errors |
| `:sidekiq` | — | for existing Redis/Sidekiq setups (`gem "sidekiq"`) |

```ruby
config.jobs.adapter = :sidekiq
```

With Sidekiq, GemStack's own retry and discard rules still decide what
happens, so jobs behave the same on every adapter. Run Sidekiq with a file that
boots the app:

```ruby
# config/sidekiq.rb
require_relative "app"
GemStack.boot!
GemStack.application.eager_load!
```

```bash
bundle exec sidekiq -r ./config/sidekiq.rb -q default -q mailers
```

## Testing

Tests use the `:test` adapter, and `GemStack::TestCase` includes the helpers:

```ruby
def test_signup_sends_a_welcome_email
  post_json "/api/signups", { email: "a@example.com" }

  assert_enqueued SendWelcomeEmail, args: [json_body["id"]]
  refute_enqueued SendInvoice
  perform_enqueued_jobs                                   # runs them (and jobs they enqueue)
end

perform_enqueued_jobs { SendWelcomeEmail.perform_later(1) }   # only jobs enqueued in the block
```

Errors raised by jobs propagate out of `perform_enqueued_jobs`, so a broken
job fails the test. Discarded jobs don't raise; the returned outcomes report
`:discarded`.

## Observability

Every job emits a structured log line — `job.enqueued`, `job.performed` (with
`ms`), `job.retried` (with the error and next `run_at`), `job.failed`,
`job.discarded` — and the same events are available to code:

```ruby
GemStack::Jobs.subscribe(:failed) do |event|
  ErrorTracker.notify(event.error, job: event.job_class, attempt: event.attempt)
end
GemStack::Jobs.subscribe { |event| Metrics.increment("jobs.#{event.name}") }   # all events
```

## Configuration

| Setting | Default |
|---|---|
| `config.jobs.adapter` | `:database` (with `gemstack/db` loaded), `:async` otherwise, `:test` in tests |
| `config.jobs.queues` | `GEMSTACK_JOB_QUEUES` or `*` (all) |
| `config.jobs.concurrency` | `GEMSTACK_JOB_CONCURRENCY` or 5 |
| `config.jobs.default_queue` / `default_priority` | `"default"` / `100` |
| `config.jobs.default_max_attempts` | `10` |
| `config.jobs.poll_interval` | `5` s (safety net; NOTIFY wakes workers immediately) |
| `config.jobs.lock_timeout` | `1800` s — a job locked longer is assumed abandoned |
| `config.jobs.shutdown_timeout` | `25` s |
| `config.jobs.keep_failed` | `true` |
| `config.jobs.dashboard.enabled` | `true` |
| `config.jobs.dashboard.path` | `"/jobs"` (outside `config.http.api_path`) |
| `config.jobs.dashboard.authorization` | `nil`; local environments allow access, non-local environments deny access until a callable returning `true` is configured |
| `config.dev.jobs_command` | `bundle exec gemstack jobs` (`nil` = don't run a worker in `gemstack dev`) |

Not included (yet): recurring (cron) jobs, unique jobs, batches. For those,
the Sidekiq adapter plus Sidekiq's ecosystem is an option today.
