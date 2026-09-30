# Changelog

All GemStack gems are released together with one version.

## Unreleased

- Add the `gsk` executable alias, including app-local binstubs and matching help output.

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
