# GemStack jobs dashboard smoke test

This guide uses the checked-in `examples/shop` app and its database-backed
jobs dashboard. Run commands from `examples/shop` unless a step says otherwise.
The demo classes live in `app/jobs/demo_jobs.rb` under `DemoJobs` (for example,
`DemoJobs::SuccessJob`). The helper is `script/jobs_demo.rb`.

## 1. Before you start

You need Ruby, Bundler, and this repository's bundle installed. From the
repository root, install the example app's bundle once:

```bash
cd examples/shop
bundle install
```

The checked-in shop app loads `gemstack/db` and `gemstack/jobs`, and has a
PostgreSQL driver in its Gemfile. A local `config/database.yml` or
`DATABASE_URL` can set the connection. If neither is present, GemStack's
fallback is PostgreSQL on this machine using the database name
`shop_development`. Check the actual connection before continuing:

```bash
bundle exec gemstack doctor
```

Create the configured database and apply migrations:

```bash
bundle exec gemstack db:create
bundle exec gemstack db:migrate
```

The shop repository includes the queue and completed-history migrations. For
an app that does not have the queue migration, or an older app that needs the
completed-history migration, install the needed migration with:

```bash
bundle exec gemstack jobs:install
bundle exec gemstack db:migrate
```

Open two terminal windows. In each one:

```bash
cd /Users/mac/projects/gemstack/examples/shop
```

In Terminal 1 start only the web server on port 4000:

```bash
bundle exec gemstack server --port 4000
```

In Terminal 2 start the queue worker:

```bash
bundle exec gemstack jobs
```

The dashboard is at <http://localhost:4000/jobs>. Stop either process with
Ctrl+C. The checked-in shop app connects to PostgreSQL, so it does not use a
database file. If you adapt this guide to a SQLite app, inspect its
`config/database.yml` (the generated default is `db/development.sqlite3`) and
close any database viewer opened on that file before testing writes.

## 2. Demo jobs and helper commands

The sample jobs print their output in the worker terminal. `FailJob` has only
one allowed attempt so it reaches Failed promptly. `FlakyJob` throws an error
on its first attempt, waits one second, and succeeds on retry. `ScheduledJob`
is queued for three minutes in the future.

Copy and run one command at a time from `examples/shop`:

```bash
bundle exec ruby script/jobs_demo.rb enqueue success
bundle exec ruby script/jobs_demo.rb enqueue fail
bundle exec ruby script/jobs_demo.rb enqueue flaky
bundle exec ruby script/jobs_demo.rb enqueue slow
bundle exec ruby script/jobs_demo.rb enqueue scheduled
bundle exec ruby script/jobs_demo.rb enqueue args
bundle exec ruby script/jobs_demo.rb enqueue queue-a
bundle exec ruby script/jobs_demo.rb enqueue queue-b
bundle exec ruby script/jobs_demo.rb enqueue many 60
```

To start over, first wait for any SlowJob to finish. The reset helper refuses to
clear the queue while a job is Running. Then run:

```bash
bundle exec ruby script/jobs_demo.rb reset
```

This removes all rows from the jobs table (including failed rows) and resets
FlakyJob's first-attempt marker. Do not run it while you need any queued jobs.

## 3. Test scenarios

For each scenario, mark the checklist at the end. Use the dashboard buttons
named below; successful jobs stay in the Completed history until you delete
them.

### Success flow

**Steps**

1. Run `bundle exec ruby script/jobs_demo.rb enqueue success`.
2. Open <http://localhost:4000/jobs/ready>.
3. Confirm `DemoJobs::SuccessJob` is listed, then watch the worker terminal.

**Expected result:** the worker prints `SuccessJob finished: [...]`. The row
leaves Ready and appears in Completed after success.

**Pass/Fail:** [ ] Pass [ ] Fail

### Failure flow

**Steps**

1. Run `bundle exec ruby script/jobs_demo.rb enqueue fail`.
2. Open <http://localhost:4000/jobs/failed> after the worker processes it.
3. Click the job ID or job name.

**Expected result:** the row appears in Failed. Its detail page shows
`RuntimeError`, `GemStack smoke test failure (expected)`, and a backtrace.

**Pass/Fail:** [ ] Pass [ ] Fail

### Retry one failed job

**Steps**

1. Leave the failed FailJob from the previous step in the queue.
2. On its row or detail page, click **Retry**.
3. Watch Ready and the worker terminal.

**Expected result:** the row is made Ready for another attempt. FailJob fails
again by design and returns to Failed after its one allowed attempt.

**Pass/Fail:** [ ] Pass [ ] Fail

### Retry that succeeds

**Steps**

1. Run `bundle exec ruby script/jobs_demo.rb enqueue flaky`.
2. Observe it in Ready, then in Failed briefly if the page refresh catches the
   first attempt.
3. Wait for the one-second retry delay and check the worker terminal and
   dashboard counts.

**Expected result:** the worker prints the first-attempt error and then
`FlakyJob succeeded on retry`. The job leaves Ready and appears in Completed.
Depending on timing, the brief Failed state may be too short to see in the UI;
the worker log still shows the retry and success.

**Pass/Fail:** [ ] Pass [ ] Fail

### Scheduled flow

**Steps**

1. Run `bundle exec ruby script/jobs_demo.rb enqueue scheduled`.
2. Open <http://localhost:4000/jobs/scheduled>.
3. Click **Run now** on `DemoJobs::ScheduledJob`.
4. Watch Ready and the worker terminal.

**Expected result:** it first appears under Scheduled. **Run now** makes it
eligible immediately; the worker prints its message and its row appears in
Completed.

**Pass/Fail:** [ ] Pass [ ] Fail

### Running flow

**Steps**

1. Run `bundle exec ruby script/jobs_demo.rb enqueue slow`.
2. Quickly open <http://localhost:4000/jobs/running>.
3. Wait about 60 seconds and refresh the page if needed.

**Expected result:** `DemoJobs::SlowJob` stays Running while it sleeps. The
worker prints start and finish messages. Its row then appears in Completed.

**Pass/Fail:** [ ] Pass [ ] Fail

### Delete one Ready, Scheduled, or Failed job

**Steps**

1. For Ready, enqueue `success`; click **Delete** on its Ready row before the
   worker takes it.
2. For Scheduled, enqueue `scheduled`; click **Delete** on its Scheduled row.
3. For Failed, enqueue `fail`, wait until Failed, then click **Delete** there.
4. Confirm each delete in the browser popup.

**Expected result:** each selected row disappears. The page shows an updated
count. Running jobs cannot be deleted from the dashboard.

**Pass/Fail:** [ ] Pass [ ] Fail

### Bulk actions

**Steps**

1. Enqueue two `fail` jobs and wait until both are Failed. Select both rows and
   click **Retry selected**.
2. Enqueue two `scheduled` jobs. Select both rows and click **Run now
   selected**.
3. Enqueue two more `scheduled` jobs. Select them and click **Delete
   selected**. Accept the **Delete the selected jobs?** confirmation popup.

**Expected result:** retry returns failed jobs to Ready (these FailJobs fail
again); Run now updates scheduled jobs so the worker can claim them; Delete
selected removes unlocked jobs after confirmation. Controls are disabled where
the selected tab cannot use an action. The dashboard accepts up to 100 IDs in
one bulk request.

**Pass/Fail:** [ ] Pass [ ] Fail

### Pagination

**Steps**

1. Stop the worker with Ctrl+C in Terminal 2 so it does not consume these rows.
2. Run `bundle exec ruby script/jobs_demo.rb enqueue many 60`.
3. Open <http://localhost:4000/jobs/ready>. Check page 1, then click **Next** or
   page **2**, then **Previous**.
4. Check the summary text. Apply the Queue filter (the helper uses `default`),
   change pages if offered, and check the URL.
5. Restart the worker with `bundle exec gemstack jobs` in Terminal 2.

**Expected result:** page 1 shows `Showing 1–25 of 60`, page 2 shows
`Showing 26–50 of 60`, and page links include Next/Previous as applicable.
Changing pages preserves the selected state tab and queue in the URL. (The
navigation page size is 25.)

**Pass/Fail:** [ ] Pass [ ] Fail

### Queue filter

**Steps**

1. Stop the worker, then run `bundle exec ruby script/jobs_demo.rb enqueue
   queue-a` and `bundle exec ruby script/jobs_demo.rb enqueue queue-b`.
2. Visit each tab, such as `/jobs/ready`, `/jobs/all`, and `/jobs/failed`.
3. In the Queue selector choose `smoke-a` and click **Apply**; repeat for
   `smoke-b`.
4. Restart the worker when done.

**Expected result:** each filter shows only the matching queue, and its state
counts and pagination summary reflect that queue. Since these examples are
Ready jobs, other state tabs correctly show no matching rows.

**Pass/Fail:** [ ] Pass [ ] Fail

### Counts

**Steps**

1. Create one or more jobs in different states (for example, enqueue a FailJob
   and a ScheduledJob).
2. Compare the badges in the top navigation, state tabs, overview summary
   cards, and Overview → Queues table.

**Expected result:** badges and totals match the rows in the database for each
state and queue. A row contributes to exactly one state count.

**Pass/Fail:** [ ] Pass [ ] Fail

### Empty states

**Steps**

1. Run `bundle exec ruby script/jobs_demo.rb reset` after ensuring no job is
   running.
2. Open `/jobs/all`, `/jobs/ready`, `/jobs/scheduled`, `/jobs/running`,
   `/jobs/failed`, and `/jobs/completed`.

**Expected result:** empty lists show friendly text such as `No ready jobs.` and
`No completed jobs.`;
overview says `No jobs have been queued yet.` Pagination says `No jobs to
show`.

**Pass/Fail:** [ ] Pass [ ] Fail

### URLs and old URL redirects

**Steps**

Open each URL in a browser:

- <http://localhost:4000/jobs>
- <http://localhost:4000/jobs/all>
- <http://localhost:4000/jobs/ready>
- <http://localhost:4000/jobs/scheduled>
- <http://localhost:4000/jobs/running>
- <http://localhost:4000/jobs/failed>
- <http://localhost:4000/jobs/completed>
- <http://localhost:4000/jobs/99999> (also covered below as bad input)
- <http://localhost:4000/jobs/jobs>
- <http://localhost:4000/jobs/jobs?state=failed>

For a real job ID, also open `http://localhost:4000/jobs/ID`, replacing `ID`
with the numeric ID shown in the table.

**Expected result:** all current routes load. `/jobs/jobs` redirects to
`/jobs/all`; `/jobs/jobs?state=failed` redirects to `/jobs/failed`. A numeric
job detail route opens its detail page.

**Pass/Fail:** [ ] Pass [ ] Fail

### Bad input and stale retry

**Steps**

1. Open <http://localhost:4000/jobs/99999>.
2. Enqueue FailJob and wait until it is Failed. Note its ID and click Delete.
3. If you still have a browser page open for that failed job, click Retry there.

**Expected result:** the missing detail shows **Job not found**. A retry against
the now-deleted row is rejected as a changed state (HTTP 409 page) instead of
crashing the server. The UI does not promise a custom friendly message for this
stale-action case; verify it remains a handled page and not a 500.

**Pass/Fail:** [ ] Pass [ ] Fail

### Database lock check

**Steps**

1. Keep the worker running.
2. Quickly enqueue a few FailJobs, retry them, and delete unlocked rows from
   the dashboard.
3. Watch the browser and both terminal logs.

**Expected result:** the dashboard should respond and there should be no
`database is locked` message. This checked-in shop app is configured for
PostgreSQL fallback, not SQLite; repeat with your own SQLite setup if SQLite
locking is what you need to assess.

**Pass/Fail:** [ ] Pass [ ] Fail

### Auto refresh

**Status:** not supported by this dashboard. There is no auto-refresh toggle or
periodic table refresh in the dashboard code. Enqueueing from a terminal will
not update an already open page until you reload it.

**Pass/Fail:** [ ] Not applicable — feature does not exist

## 4. Final checklist

| Scenario | Pass/Fail | Notes |
|---|---|---|
| Success flow and Completed history | [ ] Pass [ ] Fail | |
| Failure flow | [ ] Pass [ ] Fail | |
| Retry one failed job | [ ] Pass [ ] Fail | |
| Retry that succeeds | [ ] Pass [ ] Fail | |
| Scheduled flow | [ ] Pass [ ] Fail | |
| Running flow | [ ] Pass [ ] Fail | |
| Delete Ready, Scheduled, Failed | [ ] Pass [ ] Fail | |
| Bulk actions and confirmation | [ ] Pass [ ] Fail | |
| Pagination and preserved filters | [ ] Pass [ ] Fail | |
| Queue filter | [ ] Pass [ ] Fail | |
| Counts | [ ] Pass [ ] Fail | |
| Empty states | [ ] Pass [ ] Fail | |
| Current and legacy URLs | [ ] Pass [ ] Fail | |
| Missing job and deleted-job retry | [ ] Pass [ ] Fail | |
| Database lock check | [ ] Pass [ ] Fail | |
| Auto refresh | Not applicable | Not implemented |

## 5. Troubleshooting

### Jobs stay in Ready

Check that the worker is running in Terminal 2 and that it has not exited with
an error. The working command is `bundle exec gemstack jobs`. The worker reads
all queues by default; if you started it with `-q`, make sure its queue list
includes the job's queue. Check `bundle exec gemstack jobs:status` for counts.

### “database is locked” appears

Close any database viewer app connected to the SQLite file, if you are using
SQLite. Confirm that the web server and worker use the same database settings.
SQLite permits one writer at a time. The example shop is configured to use its
PostgreSQL fallback unless `DATABASE_URL` overrides it.

### A 503 or 500 page appears

For 503, check database connectivity and whether `gemstack_jobs` migration has
been applied: run `bundle exec gemstack doctor`, then
`bundle exec gemstack db:migrate` if needed. For 500, check the server process
log in Terminal 1; the dashboard logs the real exception class, message, and
backtrace there. In development the 500 page may also include the exception
details.

## 6. Cleanup

Wait for SlowJob to finish, then from `examples/shop` run:

```bash
bundle exec ruby script/jobs_demo.rb reset
```

This clears all queued, scheduled, and failed job rows and the FlakyJob marker.

## Suggested command order for the full smoke test

1. `cd /Users/mac/projects/gemstack/examples/shop`
2. `bundle install`
3. `bundle exec gemstack doctor`
4. `bundle exec gemstack db:create`
5. `bundle exec gemstack db:migrate`
6. Terminal 1: `bundle exec gemstack server --port 4000`
7. Terminal 2: `bundle exec gemstack jobs`
8. Run the helper's `enqueue` commands above as each scenario needs them; use
   the dashboard at <http://localhost:4000/jobs> to inspect and operate jobs.
9. Stop the worker before pagination and queue-filter checks, then restart it.
10. Wait for any running SlowJob, then run
    `bundle exec ruby script/jobs_demo.rb reset`.

The only requested dashboard scenario that cannot be run as specified is
**auto refresh**, because that feature is not implemented. SQLite database
locking is also not exercised by the checked-in shop app's PostgreSQL setup;
use a SQLite-configured app to perform that variant of the lock check.
