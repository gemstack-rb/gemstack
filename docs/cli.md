# Command reference

Every command runs inside an application folder (the one with `config/app.rb`),
except `gemstack new`. `gsk` is a shorter executable alias for `gemstack`; all
commands work with either name. `gemstack help COMMAND` shows all options. `g`
is short for `generate`; `d` is short for `destroy`.

## Remove generated code

```bash
bin/gemstack d resource Product --dry-run
bin/gemstack destroy resource Product --yes
bin/gemstack d model Company --yes
bin/gemstack d controller Reports --yes
```

Model, controller and resource generators record file ownership, content hashes and exact route lines
in `.gemstack/generators.json`. **Commit this manifest with your generated code.** Resources generated
before ownership tracking was introduced are not tracked and require manual removal. Shared helpers,
pre-existing files and custom files are preserved. Use the app's `bin/gemstack` when testing a local
checkout so an older globally installed CLI is not selected.

`--dry-run` previews the plan without changing files or regenerating contracts. Removal prompts for
confirmation; `--yes` is required in scripts. Modified tracked files require `--force`. Edited or
ambiguous generated routes, unsafe paths, symlinks and detectable remaining Ruby model references are
refused even with `--force`. Review dynamic references, seeds and custom frontend imports yourself.
The TypeScript/OpenAPI contract is refreshed after removal unless `--skip-contract` is supplied.
If that refresh fails, run `bin/gemstack contract` after fixing the application's configuration.

Migration history is read from the selected environment (`-e ENV`, otherwise `GEMSTACK_ENV` or
development), without booting the models. Tracked migrations confirmed **pending** are removed with
the generated code; modified migrations still require `--force`. Applied migrations are retained.
If database state cannot be determined, migrations are retained with a notice. Check other deployed
environments before deleting a migration: pending locally does not mean pending everywhere.

Destroy never rolls back migrations or drops tables, so existing database rows remain. To remove a
table, first review `bin/gemstack db:status`. If its creation is the latest applied migration and the
data can be discarded, `bin/gemstack db:rollback` can undo it; run destroy again to remove the now-pending
tracked migration. Otherwise, add a separate migration that drops the table. These database operations
can delete data and must be reviewed separately.

Regenerating a resource reuses an existing `*_create_<table>.rb` migration instead of producing a
duplicate. For example, generate → migrate → destroy → generate → migrate preserves the original
table and data. New or changed fields need a separate schema migration; regeneration does not change
the retained migration. If a later migration dropped the table, write a new migration to recreate it.

## Create and run

```bash
gemstack new shop                         # SQLite; Next.js frontend; bundle + npm install; git init
gemstack new shop --database=postgresql   # or mysql2, trilogy (MySQL), sqlite3 (default)
gemstack new shop --skip-frontend         # API only, no Next.js
gemstack new shop --skip-database         # no database (no models)
gemstack new shop --skip-install          # write files only (no bundle/npm install)
gemstack new shop --skip-git

gemstack dev               # Next.js + Ruby API + jobs worker behind one port → http://localhost:3000
PORT=3001 gemstack dev     # another port
gemstack server            # only the Ruby API (Puma); alias: s
gemstack console           # IRB with the app loaded (-e production for another environment); alias: c
gemstack routes            # list API routes (-g TEXT to filter)
gemstack test              # run the Ruby tests (or: gemstack test test/models/product_test.rb); alias: t
gemstack doctor            # check the setup and say how to fix problems (--production before deploying)
gemstack version
```

## Environments

Commands that load the app take `-e ENV` (or `GEMSTACK_ENV=ENV`); without it
they use `development`:

```bash
gemstack console -e production      # IRB with the production settings and database
gemstack console -e test
gemstack server -e production -p 4000
gemstack routes -e production
gemstack db:migrate -e test         # every db:* command
gemstack jobs -e production
GEMSTACK_ENV=production gemstack console   # the same, through the environment variable
```

In production the console connects to the production database: changes are
real. The environment's variables must be set, as for the server
(`SECRET_KEY_BASE`, `DATABASE_URL`…). `gemstack dev` always runs in
development and `gemstack test` in test; generators don't depend on an
environment. Inside the console, `GemStack.env` shows the environment and `reload!` reloads application code.

## Generators

### A full feature: `resource`

```bash
gemstack g resource Product name:string price:decimal description:text:optional category:references
```

Migration, model, serializer, controller with the five REST actions, routes,
tests, the TypeScript client and Next.js pages (list, detail, new, edit).

| Option | |
| --- | --- |
| `--api-only` | backend only, no Next.js pages |
| `--frontend-only` | only the Next.js pages, for an API that already exists |
| `--actions=index,show` | a subset of `index,show,create,update,destroy` |
| `--skip-tests` | no test files |
| `--force` | overwrite existing files |

Without fields it asks for them interactively.

### A controller on its own

```bash
gemstack g controller Reports index show export
gemstack g controller Admin::Reports index        # namespaced: Admin::ReportsController
```

Its actions are in the API docs and the TypeScript client right away; add
`accepts` / `returns` for typed input and output
([documenting custom endpoints](typescript.md#documenting-custom-endpoints)).

`app/controllers/reports_controller.rb` (one method per action), a test per
action and the routes. `index`, `show`, `create`, `update` and `destroy` get
REST routes; any other action becomes `GET /api/reports/<action>`.

### A model on its own

```bash
gemstack g model Product name:string price:decimal sku:string:unique
gemstack db:migrate
```

The migration, `app/models/product.rb` (`< ApplicationModel`),
`app/serializers/product_serializer.rb` and a model test — no controller, no
pages.

### A migration on its own

```bash
gemstack g migration AddStockToProducts stock:integer
gemstack g migration CreateTags name:string:unique
```

### A background job

```bash
gemstack g job SendDigest              # queue "default"
gemstack g job SendDigest mailers      # on the "mailers" queue
```

`app/jobs/send_digest.rb` (`< ApplicationJob`) and a test; the first job also
adds the jobs table migration (`gemstack db:migrate`). Run it with
`SendDigest.perform_later(...)`.

### A policy (with `gemstack add auth`)

```bash
gemstack g policy Order                # app/policies/order_policy.rb + test
```

### Deployment files

```bash
gemstack g deploy                      # Dockerfile, compose.yaml, Caddyfile, Procfile, .dockerignore
```

### Field syntax

`name:type[:optional][:unique][:index]` — fields are required unless marked
`optional`.

| Type | Database | TypeScript |
| --- | --- | --- |
| `string` | varchar(255) | `string` |
| `text` | text | `string` |
| `integer`, `bigint`, `float` | integer, bigint, float | `number` |
| `decimal` | numeric(12,2) | `string` (exact) |
| `boolean` | boolean | `boolean` |
| `date`, `datetime` | date, timestamp (UTC) | `string` (ISO 8601) |
| `uuid` | uuid | `string` |
| `json` | json/jsonb | `unknown` |
| `references` | a foreign key `<name>_id` | `number` |

### Next.js pages

Pages come with a resource (`g resource`, or `g resource … --frontend-only` for
an existing API). For any other page, add
`frontend/app/<path>/page.tsx` yourself and call the API through the
generated client:

```tsx
"use client";
import { useQuery } from "@tanstack/react-query";
import { reports } from "@/lib/api/generated";

export default function ReportsPage() {
  const { data } = useQuery({ queryKey: ["reports"], queryFn: () => reports.list() });
  return <pre>{JSON.stringify(data, null, 2)}</pre>;
}
```

The generated types and clients update themselves while `gemstack dev` runs
(or with `gemstack contract`).

## Database

```bash
gemstack db:create         # create the database (SQLite: the file) — gemstack new already does this
gemstack db:migrate        # apply pending migrations (--target VERSION to go up or down to one)
gemstack db:rollback       # undo the last migration (--steps 2 for more)
gemstack db:status         # which migrations have run
gemstack db:seed           # load db/seeds.rb
gemstack db:setup          # create + migrate + seed
gemstack db:reset          # drop + setup (development and test only)
gemstack db:drop           # refused in production unless GEMSTACK_ALLOW_DB_DROP=1
```

Add `-e test` (or `GEMSTACK_ENV=test`) to run one against the test database.
Connections: [databases](database.md).

## Optional modules

```bash
gemstack add auth          # sign up / log in, password reset, email verification, API tokens, policies
gemstack add storage       # file uploads to disk or S3
gemstack add realtime      # GemStack.broadcast → browsers (Server-Sent Events)
```

## Background jobs and the contract

```bash
gemstack jobs              # run a worker (gemstack dev runs one for you)
gemstack jobs:status       # ready / scheduled / running / failed per queue
gemstack jobs:failed       # recent failures with their errors
gemstack jobs:retry [IDS]  # put failed jobs back on the queue
gemstack jobs:discard [IDS]
gemstack contract          # regenerate TypeScript types, API clients and openapi.json for every route
                          # (custom controllers too: docs/typescript.md#documenting-custom-endpoints)
```
