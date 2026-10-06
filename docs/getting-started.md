# Getting started

## Requirements

- **Ruby 3.3 or newer** (3.3, 3.4 and 4.0 are tested) with Bundler
- **Node.js 20.9 or newer** and npm (for the Next.js frontend)
- New apps use SQLite, which needs nothing else; `--database=postgresql` or
  `--database=mysql2` need that server ([databases](database.md))

Install Ruby and Node.js with whatever you already use — for example:

| Tool | Ruby | Node.js |
| --- | --- | --- |
| rbenv / nodenv | `rbenv install 3.4.1 && rbenv global 3.4.1` | `nodenv install 22.11.0 && nodenv global 22.11.0` |
| rvm / nvm | `rvm install 3.4.1 && rvm use 3.4.1 --default` | `nvm install 22 && nvm alias default 22` |
| asdf | `asdf install ruby 3.4.1 && asdf set -u ruby 3.4.1` | `asdf install nodejs 22.11.0 && asdf set -u nodejs 22.11.0` |
| mise | `mise use -g ruby@3.4` | `mise use -g node@22` |
| Homebrew | `brew install ruby` | `brew install node@22` |

`ruby -v` and `node -v` show what's active. If a project folder pins another
version (a `.ruby-version`, `.nvmrc` or `.tool-versions` in it or a parent
folder), your tool switches to that version there.

Install the `gemstack` command:

```bash
gem install gemstack
```

GemStack also installs `gsk` as a shorter alias for `gemstack`.

New apps pin the Ruby that created them in `.ruby-version` and `.tool-versions`,
and Node.js in `.node-version`, `.nvmrc` and `.tool-versions`, so rbenv, rvm,
chruby, asdf, mise, nvm, fnm and nodenv all pick the right versions inside the
app. `gemstack doctor` says if they don't, with the command for your tool.

## Create an application

```bash
gemstack new shop
cd shop
gemstack dev
```

`gemstack new` writes the app, runs `bundle install`, creates and migrates the
database (`gemstack db:create db:migrate` — the jobs table is there from the
start), runs `npm install`, and initialises git. With
PostgreSQL or MySQL, put credentials in `config/database.yml` (or
`DATABASE_URL` / `TEST_DATABASE_URL` in `.env`) and run `gemstack db:create`.

Open **http://localhost:3000** — the starter page calls
`GET /api/health` from the browser and shows whether the Ruby API answered.

`gemstack dev` prints:

```text
  GemStack v0.4.2 · development

  ✓ Gateway    http://localhost:3000  (/api/* → Ruby, everything else → Next.js)
  … Ruby API   starting on 127.0.0.1:52011 (internal)
  … Next.js    starting on 127.0.0.1:52012 (internal)

  Application: http://localhost:3000

gemstack│ ✓ Ruby API ready (0.5s)
gemstack│ ✓ Next.js ready (1.3s)
api     │ 12:45:34.040 INFO  GET /api/health status=200 ms=3.9 id=7e6c…
```

The gateway owns port 3000 — the only one you use — and routes `/api/*` (HTTP
and the realtime WebSocket) to the Ruby API and everything else to Next.js,
both on internal ports chosen automatically (`PORT=4000 gemstack dev` changes
the public one). A jobs worker runs alongside for `perform_later`. Ctrl-C stops
everything.

## Add a resource

```bash
gemstack generate resource Product name:string price:decimal description:text:optional
gemstack db:migrate
```

Open **http://localhost:3000/products** — list, create, view, edit and delete
products. The pages use a TypeScript client generated from the backend
(`frontend/lib/api/generated/`), which `gemstack dev` keeps in sync as you
change serializers, schemas or routes. See [resource generation](resource-generation.md).

## Add a custom endpoint

```bash
gemstack generate controller Status show
```

creates `app/controllers/status_controller.rb`, a test, and the route
`get "/status/:id", to: "status#show"` in `config/routes.rb`. Edit the action:

```ruby
class StatusController < ApplicationController
  def show
    render({ id: params[:id], time: Time.now })
  end
end
```

Save and request it — no restart needed:

```bash
curl localhost:3000/api/status/1
# {"id":"1","time":"2026-09-28T12:00:00.000Z"}
```

Call it from the frontend (`frontend/app/page.tsx`):

```tsx
const status = useQuery({ queryKey: ["status", 1], queryFn: () => api.get<{ id: string }>("/status/1") });
```

## Run the tests

```bash
gemstack test          # Ruby (Minitest + rack-test)
cd frontend && npm run typecheck
```

## What's in the project

```text
config/app.rb        GemStack.configure — settings for every environment
config/environments/ development.rb, test.rb, production.rb — per-environment settings, defaults as comments
config/database.yml  the database connection per environment
config/routes.rb     routes, relative to /api
config/puma.rb       server settings (threads/workers via ENV)
app/controllers/     ApplicationController and yours
app/models/          ApplicationModel and yours
app/serializers/     ApplicationSerializer and yours
app/jobs/            ApplicationJob and yours (background jobs)
app/mailers/         ApplicationMailer and yours; templates/ for their ERB
                     (any other app/<dir> autoloads too: services/, policies/…)
db/migrations/       Sequel migrations; db/seeds.rb for development data
test/                GemStack::TestCase tests
frontend/            Next.js App Router + TypeScript + TanStack Query
bin/gemstack         CLI binstub for this app's bundle
```

There is no User model, no authentication and no CRUD: you decide what the
application contains. Add them when you need them: `gemstack add auth`
([authentication](authentication.md)), `gemstack add storage` ([storage](storage.md)).

All commands and generators: [command reference](cli.md).

Something not working? `gemstack doctor` checks your setup and says what to fix; while `gemstack dev`
runs, [http://localhost:3000/api/docs](http://localhost:3000/api/docs) lists every endpoint
([development tools](development.md)).

Next: [routing](routing.md), [controllers](controllers.md), [configuration](configuration.md).
