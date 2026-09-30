# GemStack

**A fast, modular Ruby API framework for Next.js applications** — by [Adware Technologies](https://www.adwaretech.com).

GemStack lets you start a Ruby + Next.js + TypeScript application and go straight
to business logic. One command gives you a Ruby API and a Next.js frontend served
from **one origin**, with production-ready defaults (security headers, request
IDs, structured logs, body limits, JSON errors) and no plumbing to wire.

```bash
gemstack new shop
cd shop
gsk dev                # → http://localhost:3000 (or `gemstack dev`)
```

```text
                 Browser
                    │
             localhost:3000          one origin: no CORS, no API URL, no proxy config
                    │
             GemStack gateway
               /          \
         Next.js           /api/*  → Ruby (Rack + Puma)
```

## Why

- **Convention over configuration.** Routes live under `/api`, code in `app/`
  autoloads, the dev server picks its own internal ports. Configure only what
  differs.
- **Smart defaults, not rigid defaults.** Every subsystem can be configured,
  swapped (codec, middleware, adapters) or replaced — it's plain Rack, plain
  Bundler and plain Next.js underneath.
- **Not Rails.** API-first, small core, no server-rendered views, no default
  User/auth/CRUD. The generated app is intentionally empty.
- **Normal ecosystems.** Any gem via the Gemfile, any npm package in
  `frontend/`.
- **Fast by default, measured.** O(1) static routing, a compiled middleware
  stack, lazy body parsing, C-backed JSON — with benchmarks in `benchmarks/`.

## A taste

```bash
gemstack generate resource Product name:string price:decimal description:text:optional
gemstack db:migrate
```

generates the migration, model, serializer, controller, routes, tests, a typed
TypeScript client and Next.js pages. The pieces stay small and readable:

```ruby
class Product < ApplicationModel
  field :name, :string, null: false, size: 255     # declared once: validations, request schema,
  field :price, :decimal, null: false               # serializer types and TypeScript all derive from it
  field :description, :text
end

class ProductSerializer < ApplicationSerializer
  attributes :id, :name, :price, :description, :created_at, :updated_at
end

class ProductsController < ApplicationController
  accepts :create, with: Product.input_schema

  def index = render(Product.order(:id))
  def show = render(Product.find(params[:id]))                  # 404 when missing
  def create = render(Product.create(input), status: :created)  # 422 with field errors when invalid
end
```

```ts
// frontend/lib/api/generated — written by `gemstack contract`, never by hand
import { products, type Product } from "@/lib/api/generated";
const created: Product = await products.create({ name: "Lamp", price: "9.99" });
```

## Commands

| Command | |
|---|---|
| `gemstack new NAME` | new app (`--database=sqlite3\|postgresql\|mysql2\|trilogy`, `--skip-frontend`, `--skip-database`, `--skip-install`, `--skip-git`) |
| `gemstack dev` | Next.js + Ruby API + jobs worker on one port |
| `gemstack server` / `s` | the Ruby API alone (Puma) |
| `gemstack g resource Product name:string price:decimal` | full vertical slice: migration, model, API, TypeScript client, Next.js pages (`--api-only`, `--frontend-only`, `--actions=`) |
| `gemstack g controller Reports index show` | a controller on its own, with routes and tests |
| `gemstack g model Product name:string` | a model on its own: migration, model, serializer, test |
| `gemstack g migration AddStockToProducts stock:integer` | a migration |
| `gemstack g job SendDigest [QUEUE]` | a background job (`gemstack jobs` runs a worker) |
| `gemstack g policy Order` / `gemstack g deploy` | an authorization policy / Docker, compose, Caddy, Procfile |
| `gemstack db:create` · `db:migrate` · `db:rollback` · `db:status` · `db:seed` · `db:setup` · `db:reset` · `db:drop` | the database (`gemstack new` already runs `db:create`) |
| `gemstack add auth\|storage\|realtime` | optional modules |
| `gemstack doctor` | check the setup and how to fix it (`--production` before deploying) |
| `gemstack contract` | regenerate TypeScript types, API clients, OpenAPI |
| `gemstack routes` · `gemstack test` / `t` · `gemstack console` / `c` · `gemstack version` | |

Every option, the field types and how to add other Next.js pages:
[command reference](docs/cli.md).

## Installation

Requirements: **Ruby 3.3 or newer** (tested on 3.3, 3.4 and 4.0; installed any way you like —
rbenv, rvm, asdf, mise, chruby or a package manager), **Node.js 20.9+** and npm. Apps
use SQLite by default; `--database=postgresql` or `--database=mysql2` for a
server database ([databases](docs/database.md)).

```bash
gem install gemstack
gemstack new shop                  # Gemfile: gem "gemstack", "~> 0.3.0"
```

One gem is the framework: routing, controllers, models, background jobs, mail,
file storage, the TypeScript contract, generators and the dev server. An app
switches modules on in `config/app.rb`, the way a Rails app does in
`application.rb`:

```ruby
require "gemstack"
require "gemstack/db"       # models and migrations (config/database.yml)
require "gemstack/jobs"     # background jobs
require "gemstack/mail"     # mailers
# require "gemstack/storage" # file uploads — gemstack add storage
```

Authentication (`gemstack-auth`) and realtime (`gemstack-realtime`) are
separate gems because they compile native extensions; `gemstack add auth` and
`gemstack add realtime` add them. `gemstack-cli` holds the `gemstack` and `gsk`
executable launchers and comes with `gemstack`. All gems are released together, with
one version.

**Hacking on GemStack itself?** Clone this repository (every gem lives in
`gems/` and is published from here). `bin/gemstack` and `bin/gsk` run
the CLI straight from the checkout, and apps it creates point their Gemfile at
the checkout (`path "…/gems"`), so framework changes apply immediately.
`bundle exec rake gems:install` installs the checkout's gems as if released.

See [`examples/shop`](examples/shop) for a complete example application.

## Repository layout

```text
gems/
  gemstack/          the framework gem
    lib/gemstack/    one directory per module: core, cache, schema, http, db, jobs, mail,
                     storage, contract, dev, cli (+ Application, reloading, test helpers)
    templates/       what the generators write
    test/<module>/   the tests of each module
  gemstack-cli/      the `gemstack` executable
  gemstack-auth/     authentication and policies (argon2)
  gemstack-realtime/ Server-Sent Events (nio4r)
docs/                guides
benchmarks/          performance measurements
examples/shop/       an example application
ARCHITECTURE.md      how GemStack is put together · CHANGELOG.md releases
```

## Developing GemStack

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for setup, where tests go and how
pull requests are checked. Report vulnerabilities privately: [SECURITY.md](SECURITY.md).

```bash
bundle install
bundle exec rake          # all tests + RuboCop
bundle exec rake test:http             # one module (test:db, test:cli, test:auth, …)
bundle exec rake test:changed          # the modules your branch changes
bundle exec rake "test:new[http,rate_limiting]"   # start a test file in a module
GEMSTACK_TEST_DATABASE_URL=postgres://user:pass@localhost/gemstack_test bundle exec rake test:db
bundle exec rake test:databases        # db, jobs and auth on SQLite (+ PostgreSQL/MySQL when configured)
script/ruby-matrix                     # the suite on Ruby 3.3, 3.4 and 4.0 (Docker)
script/e2e                             # generate a full app and run its tests, TypeScript and next build
bundle exec rake bench
```

## Documentation

[Getting started](docs/getting-started.md) ·
[Philosophy](docs/philosophy.md) ·
[Architecture](docs/architecture.md) ·
[Configuration](docs/configuration.md) ·
[Routing](docs/routing.md) ·
[Controllers](docs/controllers.md) ·
[Next.js](docs/nextjs.md) ·
[TypeScript](docs/typescript.md) ·
[Testing](docs/testing.md) ·
[Performance](docs/performance.md) ·
[Deployment](docs/deployment.md) ·
[Resource generation](docs/resource-generation.md)

[Commands](docs/cli.md) · [Databases](docs/database.md) · [Models](docs/models.md) · [Pagination](docs/pagination.md) · [Validation](docs/validation.md) ·
[Serialization](docs/serialization.md) · [Caching](docs/caching.md) ·
[Background jobs](docs/background-jobs.md) · [Realtime](docs/realtime.md) ·
[Authentication](docs/authentication.md) · [Authorization](docs/authorization.md) ·
[Mail](docs/mail.md) · [Storage](docs/storage.md) · [Development tools](docs/development.md)

## About

GemStack is developed and maintained by **[Adware Technologies](https://www.adwaretech.com)**.

## License

GemStack is open source, available under the [MIT License](LICENSE.txt) —
© 2026 [Adware Technologies](https://www.adwaretech.com). You may use it,
modify it and build commercial products with it; keep the copyright and
license notice.
