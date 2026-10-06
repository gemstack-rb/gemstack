# Changelog

All GemStack gems are released together with one version.

## 0.4.1

- **One `.env` for the API and the frontend**: the root one. `frontend/lib/gemstack/root-env.cjs` loads the
  root `.env` files for Next.js (same order as the API, real environment first): `next.config.ts` requires
  it, so `next dev`, `next build` and `next start` get the values wherever they run, and the standalone
  server preloads it (`npm run start:standalone`, i.e.
  `node -r ./lib/gemstack/root-env.cjs .next/standalone/server.js`). Before, a production build outside
  `gemstack dev` compiled `NEXT_PUBLIC_*` values in as undefined, and the standalone server's server-side
  code only saw real environment variables. The API now loads the root `.env` files in production too, when
  present (real environment variables still win). The Docker image built by `gemstack generate deploy` gets
  the root `.env`'s `NEXT_PUBLIC_*` lines as a build secret for `next build` (`.kamal/secrets`:
  `GEMSTACK_PUBLIC_ENV`), never stored in the image, and its web command preloads the loader too. Existing
  apps: `gemstack update` adds the loader and updates `next.config.ts` and `package.json`; re-run
  `gemstack generate deploy` for the Docker/Kamal part.
- `gemstack update`: files you edited that the release also changed can be **merged** — `[m]erge` keeps
  your edits and applies the release's template changes on top (three-way, `git merge-file`), with conflict
  markers only where both changed the same lines. Before, the choices were overwrite (losing your edits),
  skip, diff or save as `FILE.new`.

## 0.4.0

Upgrading from 0.3.x: run `gemstack update` (it also updates the files `gemstack new` wrote). Apps that
added realtime: copy `frontend/lib/gemstack/realtime.ts` from a fresh `gemstack add realtime` for
WebSockets, `realtime.send`, presence and the `offline` status — the old client keeps working over
Server-Sent Events. Validation error messages now list the failures (the `errors` hash is unchanged).

- **Model enums**: `enum :status, %w[draft published archived], default: "draft"` — a string column
  limited to those values, validated, accepted only with those values by the request schema, typed
  `"draft" | "published" | "archived"` in TypeScript and OpenAPI, with `Product.statuses`, `draft?`,
  `published!` and chainable `Product.published` (`prefix:` for clashes). Generators take
  `status:enum:draft,published,archived` (migration column, the `enum` line, a `<select>` in the form).
  Schemas and fields take `enum:` too.
- Validation errors say what failed in their message — "Validation failed: price must be greater than 0" —
  not only in `errors`, and generated forms show the message when an error belongs to no field in the form
  (e.g. `errors.add(:base, …)`); before, such errors left the form without any message.
- **Realtime runs over WebSockets.** `gemstack add realtime` gives one WebSocket per browser tab on
  `/api/realtime` (same origin; the dev gateway and kamal-proxy route it with `/api`), carrying
  subscriptions, broadcasts, browser → server messages (`realtime.send` → `receive` in
  `config/channels.rb`, with replies), presence (`channel "rooms:*", presence: true`, `usePresence`,
  `GemStack::Realtime.present_on`), connection identity (`identify`) and replay after reconnects. The
  browser client reconnects with backoff, resubscribes and de-duplicates; Origins are checked and
  messages are size- and rate-limited. `GemStack.broadcast`, channel rules and brokers are unchanged.
- **Server-Sent Events are a full second transport** with the same features (`receive` via POST,
  presence, identity, replay). `config.realtime.transports` (default `[:websocket, :sse]`) says what the
  server accepts; `NEXT_PUBLIC_GEMSTACK_REALTIME` (`auto` — the default: WebSocket, falling back to SSE when
  one can't be opened — `websocket` or `sse`) what the browser uses. App code is the same either way.
  `useRealtimeStatus()` adds `offline` (the browser lost its network), `realtime.transport` says which one
  is in use, and presence survives a reconnect within `config.realtime.presence_grace` (3 s). Apps on the
  old `realtime.ts` keep working; copy the new client to get the rest (docs/realtime.md).
- `GemStack::Auth.user_from(request)`: the signed-in user outside controllers (session cookie or API
  token), e.g. for realtime's `identify`.
- Background jobs work from `gemstack new`: apps with a database get the jobs table, `gemstack new`
  migrates, and `gemstack dev` runs a worker from the first run. Jobs still run only via `perform_later`.
- New apps include `gem "brotli"`, so responses are Brotli-compressed for browsers that accept it
  (gzip otherwise; compression was already on by default).
- PostgreSQL is the recommended production database: `config/database.yml`, the Kamal config and
  `gemstack doctor --production` say how to use it (`DATABASE_URL`). SQLite stays the development default.
- GemStack now describes itself as "a fast, modular Ruby web application framework with a Next.js frontend"
  (README, gem READMEs and the gem summary on rubygems.org).

## 0.3.6

- **`gemstack update` updates the app's templates too.** After moving the gems, it brings the files
  `gemstack new` wrote (config, `bin/`, frontend setup, …) up to the new version, comparing your copy with
  the old and the new version's templates: files the release didn't change are left alone, new files are
  created, files you never edited are updated, and for files you edited you choose — overwrite, skip, see
  the diff, or save the new version as `FILE.new` (never overwritten without asking; scripts get a list).
  `gemstack update --templates [--from VERSION] [--dry-run]` runs that step alone. Apps record the
  templates they're on in `.gemstack/version` (new apps from this release; older apps are compared with
  the version in their `Gemfile.lock`).
- `gemstack destroy` reverses every generator: besides resources, models and controllers it now removes
  jobs, policies, migrations (same safety rules: only pending, uncommitted ones unless
  `--remove-migrations`) and the Kamal deploy files (`gemstack destroy deploy`, which also removes the
  `kamal` Gemfile line it added). Jobs and policies still named elsewhere in the app are refused; shared
  files such as `application_job.rb` and the jobs table migration are kept. Code from these generators is
  tracked from this release on.

## 0.3.5

- **`gemstack generate deploy` now sets up [Kamal](https://kamal-deploy.org)** instead of docker compose and
  Caddy: one production image for every process, `config/deploy.yml` with web, api and jobs roles
  (kamal-proxy serves one origin, routes `/api` to Ruby and handles HTTPS with Let's Encrypt; zero-downtime
  deploys), database and Redis accessories, `.kamal/secrets` (references only) and `bin/docker-entrypoint`
  (migrations before the API starts). It no longer writes `compose.yaml`, `Caddyfile` or `Procfile`;
  existing files are left alone. See [deployment](docs/deployment.md).
- `gemstack doctor` fails when `.kamal/secrets` contains a secret's value instead of a reference.
- New apps' `next.config.ts` builds Next.js's standalone server for the production image.
- Add `gemstack update [VERSION]`: moves the app to the latest GemStack release on rubygems.org (or
  VERSION) — sets every GemStack gem in the Gemfile to `~> VERSION` and runs `bundle update` for them
  together; the Gemfile is restored if that fails. Apps on a GemStack checkout are told to update it.

## 0.3.4

- Models support `delete_all` on classes and filtered queries; it skips callbacks and validations and returns the number of rows deleted.
- Add `destroy` / `d` for tracked models, controllers and resources, with preview, modified-file protection
  and contract refresh. Automatically remove only pending, uncommitted migrations; retain applied or
  committed history, with `--remove-migrations` for explicit removal of pending migrations. Reuse create
  migrations on regeneration and print migration commands for new or changed fields.

## 0.3.3

- Add the `gsk` executable alias, including app-local binstubs and matching help output.
- Add `reload!` to the console to reload application code without restarting the console.

## 0.3.2

- `gemstack` shows the real error when one of its dependencies can't be loaded, instead of saying the
  gemstack gem is missing.

## 0.3.1

- New GemStack logo: a ruby gem on a stack. New apps show it on their welcome page (light and dark
  mode); the logo files are in `docs/assets/logo/`.
- Docs: associations and eager loading in [models](docs/models.md): the Sequel equivalents of Rails'
  `includes`, `eager_load` and `joins`, and how to catch N+1 queries.

## 0.3.0

**GemStack is now one gem.** The framework — core, cache, schema, http, db, jobs, mail, storage, contract,
dev and the CLI — is the `gemstack` gem. Authentication (`gemstack-auth`) and realtime
(`gemstack-realtime`) stay separate gems because of their native extensions; `gemstack-cli` only holds the
`gemstack` executable and is installed with `gemstack`. Library code, `require` paths and class names are
unchanged.

- Apps switch modules on in `config/app.rb` (`require "gemstack/db"`, `"gemstack/jobs"`, `"gemstack/mail"`,
  `"gemstack/storage"`) instead of listing a gem per module; `gemstack new` and `gemstack add` write the lines
- `gemstack doctor` says what to change in apps from before 0.3
- The ten merged gem names get a last 0.3.0 release: a shim that depends on `gemstack` and loads its
  module, so existing Gemfiles keep working
- Releases publish four gems instead of fourteen

### Upgrading from 0.2

1. In the Gemfile, change the GemStack versions to `"~> 0.3.0"` and run `bundle update gemstack`. The app
   works as before: the old gem names now point to `gemstack`.
2. Finish the move — `gemstack doctor` lists exactly what applies to your app:
   - remove the lines for `gemstack-db`, `gemstack-jobs`, `gemstack-mail`, `gemstack-storage` (and any
     other `gemstack-*` except `gemstack-auth` and `gemstack-realtime`) from the Gemfile;
   - add the matching lines to `config/app.rb`, after `require "gemstack"`:

     ```ruby
     require "gemstack/db"
     require "gemstack/jobs"
     require "gemstack/mail"
     require "gemstack/storage"   # if you used gemstack add storage
     ```

   - run `bundle install`.

`bin/gemstack` doesn't need changes.

## 0.2.5

- Documentation: removed the internal planning documents (roadmap, decision log, release checklist)
  and the references to them; the README no longer carries a development status block

## 0.2.4

- `docs/pagination.md`: how pagination works, changing the page size (app, action, request), the
  frontend hooks, filtering, large tables
- The generated `config/app.rb` lists the pagination, response, logging, database, cache, jobs and mail
  settings with their defaults
- Generated list hooks take an optional page size: `useProducts(page, perPage)`
- Docs: documenting custom endpoints — `gemstack contract` and `/api/docs` cover every route; `accepts`
  and `returns` type their input and output (`docs/typescript.md`)
- `gemstack routes -e ENV` uses that environment (it always used development); the command reference
  documents `-e` for the console, server, routes, db and jobs commands

## 0.2.3

- **Ruby 3.3 or newer** (was 4.0): tested on Ruby 3.3, 3.4 and 4.0 (`script/ruby-matrix`)
- No assumed version manager: `gemstack doctor` and `gemstack dev` print the command for the tool that
  installed your Ruby or Node.js (rbenv, rvm, asdf, mise, chruby, nvm, fnm, nodenv, Volta, Homebrew)
- `gemstack dev` stops with a clear message and the fix when Node.js is older than 20.9
- New apps pin Node.js in `.node-version`, `.nvmrc` and `.tool-versions`, next to Ruby
- Getting started lists how to install Ruby and Node.js with each common tool

## 0.2.2

- A designed welcome page for new apps (`frontend/app/page.tsx` + `page.module.css`): live Next.js and
  Ruby API checks, next steps with copyable commands, links to `/api/docs` and the guides; light and dark
- Fix: a new app's generated `types.ts` was empty, so `tsc` and `next build` failed until the first resource
- Command reference (`docs/cli.md`) and a fuller command table in the README
- GemStack is developed and maintained by Adware Technologies (https://www.adwaretech.com); the MIT
  license's copyright holder is Adware Technologies

## 0.2.1

- New apps get `config/environments/{development,test,production}.rb` listing the settings that usually
  differ per environment, commented out with their defaults
- Base classes in new apps: `ApplicationModel`, `ApplicationSerializer`, `ApplicationJob`,
  `ApplicationMailer` (next to `ApplicationController`); generators and `gemstack add auth/storage`
  inherit from them, and add them to older apps when missing
- New apps include `gemstack-mail`
- `gemstack new` generates the TypeScript contract, so `frontend/lib/api/generated` exists from the start

## 0.2.0

Databases: SQLite, PostgreSQL and MySQL, configured by `config/database.yml`.

- Rails-style `config/database.yml` (per environment, ERB); `config.db.url`, then `DATABASE_URL`
  (`TEST_DATABASE_URL` in tests), then the file
- Adapters: SQLite (`sqlite3`), PostgreSQL (`pg`), MySQL 8 (`mysql2` or `trilogy`);
  `gemstack new --database=sqlite3|postgresql|mysql2|trilogy`, SQLite by default
- Portable migrations: `timestamptz`, `jsonb`, `uuid`, `inet` map to native types on MySQL and SQLite;
  times stored in UTC; SQLite in WAL mode with a busy timeout
- The job queue, auth, storage, `gemstack doctor` and `gemstack generate deploy` work on every adapter;
  realtime fans out through Redis when the database isn't PostgreSQL
- Constraint errors become field errors on MySQL and SQLite too

### Upgrading from 0.1.0

- `gemstack-db` no longer depends on `pg`. Add the driver to your Gemfile: `gem "pg", "~> 1.5"`.
- Apps without `config/database.yml` keep using PostgreSQL `<app>_<env>` or `DATABASE_URL`, as before.
  Adding the file is optional (`docs/database.md`).
- `config.jobs.adapter = :postgres` still works; the new name is `:database`.

## 0.1.0

First release.

- HTTP layer on Rack 3: router, middleware, controllers with `accepts`/`returns`, JSON errors, security defaults
- Single-origin development: `gemstack dev` runs Next.js and the Ruby API behind one port
- PostgreSQL models on Sequel, migrations, validation, serializers
- TypeScript types, typed API clients and OpenAPI generated from the backend; `generate resource` for
  full vertical slices with Next.js pages
- Compression, ETags, pagination, `GemStack.cache`, YJIT by default
- Background jobs on PostgreSQL (transactional, `SKIP LOCKED`, `LISTEN/NOTIFY`), Sidekiq adapter
- Realtime over Server-Sent Events with PostgreSQL fan-out and `useRealtime`
- `gemstack add auth` (Argon2id, cookie sessions, API tokens, password reset, email verification, policies),
  mail, `gemstack add storage` (direct uploads to disk or S3)
- Development error pages, `/api/docs`, `gemstack doctor`, `gemstack generate deploy`
