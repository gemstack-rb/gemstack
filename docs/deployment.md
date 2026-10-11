# Deploying to production

This guide takes a GemStack app from your laptop to a live HTTPS site on your own server, step by
step. It uses [Kamal](https://kamal-deploy.org), which GemStack sets up for you: you run one command on
your machine, and Kamal builds the app, copies it to the server and switches traffic over with zero
downtime. Nothing is installed by hand on the server.

- [What you'll end up with](#what-youll-end-up-with)
- [Before you start](#before-you-start)
- [Step-by-step: the first deploy](#step-by-step-the-first-deploy)
- [Everyday commands](#everyday-commands)
- [Common tasks](#common-tasks) — your own settings, www and the bare domain, the database, more servers
- [Troubleshooting](#troubleshooting)
- [How configuration reaches production](#how-configuration-reaches-production)
- [Without Kamal](#without-kamal) — other servers and platforms
- [Production checklist](#production-checklist)

## What you'll end up with

```text
                    https://example.com
                            │
                  kamal-proxy (HTTPS, Let's Encrypt)
                  ├── /api/*  ──▶ api role   Ruby API (Puma)          ─┐
                  └── /*      ──▶ web role   Next.js                   ├─▶ PostgreSQL / MySQL
                                  jobs role  background job worker    ─┘   (a container on the server)
```

- **One server** (any Linux VM with SSH: Hetzner, DigitalOcean, AWS EC2, Google Cloud, your own box)
  runs everything in Docker containers.
- **One Docker image** holds the whole app; each role runs a different command from it.
- **kamal-proxy** gets a free HTTPS certificate for your domain and routes `/api` to Ruby and everything
  else to Next.js — the same single origin as `gemstack dev`.
- **Your database** runs as a container on the same server (a Kamal "accessory"). SQLite apps keep
  their database file on a volume instead.
- **Deploys** build a new image, start new containers, wait until they're healthy, then switch traffic.
  The api role starts first and applies pending migrations before it serves anything.

## Before you start

You need:

| | What | Notes |
| --- | --- | --- |
| 1 | **A server** with a public IP | Ubuntu or Debian, 2 GB RAM or more. Ports **22**, **80** and **443** open (on AWS: the security group). |
| 2 | **SSH access** from your machine | as `root`, or a user with passwordless `sudo` (e.g. `ubuntu` on AWS). Test it: `ssh ubuntu@203.0.113.10`. |
| 3 | **A domain** | you'll point it at the server in step 2. |
| 4 | **A container registry account** | where the image is stored between your machine and the server: Docker Hub, or GitHub's registry (ghcr.io). See step 4 for a way to skip this with one server. |
| 5 | **Docker on your machine**, running | Kamal builds the image locally. Docker Desktop is fine. |

Docker on the **server** is installed for you by the first deploy (it needs root or passwordless `sudo`;
otherwise [install Docker](https://docs.docker.com/engine/install/) there first).

## Step-by-step: the first deploy

The examples use the domain `example.com`, the server `203.0.113.10` and the app name `shop`.

### Step 1 — Generate the deploy files

In your app's folder:

```bash
gemstack generate deploy
bundle install
bundle lock --add-checksums     # only if the generator tells you to (Bundler 4 lockfiles)
```

This creates (commit them all):

| File | What it is | Do you edit it? |
| --- | --- | --- |
| `config/deploy.yml` | the Kamal configuration: server, domain, roles, database | **yes**, step 3 |
| `.kamal/secrets` | which secret values Kamal passes to the app — as *references* like `$SECRET_KEY_BASE`, never the values themselves | only to add your own settings |
| `bin/deploy` | the command you deploy with: Kamal, with your root `.env.production` / `.env` loaded | no |
| `Dockerfile` | builds the one image for every role | rarely |
| `bin/docker-entrypoint` | applies pending migrations when the api role starts | no |
| `.dockerignore` | keeps `.env` files, `.git`, keys and `node_modules` out of the image | no |

It also adds the `kamal` gem to your Gemfile (development group) and turns on Next.js's standalone
output in `frontend/next.config.ts`.

### Step 2 — Point your domain at the server

At your DNS provider, create an **A record** for your domain with the server's IP:

```text
example.com.        A    203.0.113.10
www.example.com.    A    203.0.113.10     # if you also serve www (see "www and the bare domain")
```

HTTPS certificates are issued only once the domain resolves to the server. Check with
`dig +short example.com` before deploying.

### Step 3 — Edit `config/deploy.yml`

Open it and change every line marked `# CHANGE`:

```yaml
service: shop
image: your-dockerhub-user/shop          # CHANGE: <registry user>/<app>

servers:
  web:
    hosts:
      - 203.0.113.10                     # CHANGE: your server's IP — in every role and accessory
  api:
    hosts:
      - 203.0.113.10
  jobs:
    hosts:
      - 203.0.113.10

proxy:
  ssl: true
  host: example.com                      # CHANGE: your domain

registry:
  username: your-dockerhub-user          # CHANGE

env:
  clear:
    APP_URL: https://example.com         # CHANGE: your public URL (used in email links)
    MAIL_FROM: hello@example.com         # CHANGE (apps that send email)

accessories:
  db:
    host: 203.0.113.10                   # CHANGE
```

If you log in to the server as a user other than `root`, uncomment and set:

```yaml
ssh:
  user: ubuntu
```

Leave the rest as generated: the roles, `/api` routing, health checks and `primary_role: api` (the API
starts before the frontend, whose health check renders pages that call it).

### Step 4 — Choose a container registry

Kamal pushes the image from your machine to a registry, and the server pulls it from there.

- **Docker Hub** (the default): create an access token under *Account settings → Personal access
  tokens*. It becomes `KAMAL_REGISTRY_PASSWORD` in step 5.
- **GitHub's registry**: set `server: ghcr.io` under `registry:` and your GitHub user as `username`. In
  `.kamal/secrets`, let the GitHub CLI supply the token:

  ```bash
  gh auth refresh -s write:packages      # once
  ```

  ```bash
  # .kamal/secrets
  KAMAL_REGISTRY_PASSWORD=$(gh auth token)
  ```

- **No registry account** (one server only): set `server: localhost:5555` under `registry:` and remove
  `username:` and `password:`; Kamal pushes the image to the server over SSH.

### Step 5 — Put the production values in `.env.production`

Production settings live in one file at the app root, **`.env.production`**, next to the `.env` you
use in development. It's git-ignored (`.env.*` in the `.gitignore` of apps created with GemStack 0.4.3
or later; in older apps, `gemstack update` adds it — or add `.env.*` and `!.env.example` yourself, and
check with `git check-ignore .env.production`): it stays on your machine and is read by `bin/deploy`
each time you deploy.

```bash
# .env.production — never commit this file
KAMAL_REGISTRY_PASSWORD=dckr_pat_…          # step 4 (not needed with $(gh auth token) or localhost:5555)
SECRET_KEY_BASE=…                           # run: openssl rand -hex 64 — keep the same value forever
POSTGRES_PASSWORD=…                         # run: openssl rand -hex 16 (MySQL apps: MYSQL_PASSWORD)
SMTP_URL=smtp://user:password@smtp.example.com:587   # apps that send email; leave empty until then
# NEXT_PUBLIC_MAPBOX_TOKEN=pk.…             # the frontend's public settings, if it has any
```

Which variables you need is exactly the list in `.kamal/secrets`. You don't write `DATABASE_URL`:
`.kamal/secrets` builds it from `POSTGRES_PASSWORD` and the database container's name.

Values that are the same in development and production can stay in `.env`; `.env.production` wins
where both have a value. `.env.local` is never used for deploys (it holds your development overrides).

### Step 6 — Check and commit

```bash
gemstack doctor                  # fails if a secret value (not a $REFERENCE) is in .kamal/secrets,
                                 # or if .env files or keys are tracked by git
git add -A && git commit -m "Deploy with Kamal"
```

Kamal builds the image **from your last commit**, so anything uncommitted isn't deployed —
`bin/deploy` refuses to run until you commit.

### Step 7 — Deploy for the first time

```bash
bin/deploy setup
```

This takes a few minutes the first time. Kamal:

1. connects to the server and installs Docker if it's missing;
2. starts the database container;
3. builds the image on your machine and pushes it to the registry;
4. starts kamal-proxy, then the api role (which applies migrations), the web role and the jobs worker,
   waiting for each to pass its health check;
5. gets the HTTPS certificate on the first request to your domain.

Then check it:

```bash
curl https://example.com/api/health      # {"status":"ok"}
```

and open `https://example.com` in a browser. To check the production settings on the server itself
(secret key, database, mail):

```bash
bin/deploy app exec --roles=api "bundle exec gemstack doctor --production"
```

If something fails, see [Troubleshooting](#troubleshooting).

### Step 8 — Every deploy after that

```bash
git commit -am "…"
bin/deploy
```

### Later GemStack releases

`gemstack update` also updates the deploy files, keeping your edits: unedited files are updated, and
for edited ones (like `config/deploy.yml`, with your server and domain) you can merge the release's
changes into yours ([updating](cli.md#upgrading-gemstack)). Review the result and deploy.

## Everyday commands

`bin/deploy` passes anything after it to Kamal, with your `.env.production` / `.env` loaded:

```bash
bin/deploy                     # build, push and switch to the last commit (zero downtime)
bin/deploy logs                # follow the app's logs
bin/deploy console             # gemstack console on the server
bin/deploy migrate             # run pending migrations (deploys already do this)
bin/deploy shell               # a shell inside the api container
bin/deploy app details         # what's running
bin/deploy rollback VERSION    # go back to an earlier image (versions: bin/deploy app containers)
```

`bin/deploy` is a small script around `gemstack deploy`; `gemstack deploy logs` is the same command.

## Common tasks

### Add a setting your app reads from ENV

Say your app uses `ENV["GOOGLE_CLIENT_SECRET"]`. A **secret** value needs three lines:

1. the value, in `.env.production`:
   `GOOGLE_CLIENT_SECRET=…`
2. a reference, in `.kamal/secrets` (committed — the name only, never the value):
   `GOOGLE_CLIENT_SECRET=$GOOGLE_CLIENT_SECRET`
3. its name, in `config/deploy.yml`:

   ```yaml
   env:
     secret:
       - GOOGLE_CLIENT_SECRET
   ```

A value that **isn't secret** (a public callback URL, a feature flag) goes straight into
`config/deploy.yml`, nothing else:

```yaml
env:
  clear:
    GOOGLE_REDIRECT_URI: https://example.com/api/auth/google/callback
```

A **frontend** setting the browser needs is a `NEXT_PUBLIC_*` variable: put it in `.env.production`
(or `.env`) and deploy. It's compiled into the JavaScript during the build, so changing it needs a new
deploy, and it's public by nature — never put a secret in a `NEXT_PUBLIC_*` variable.

Then commit and `bin/deploy`.

### Serve www and the bare domain

Point both names at the server (step 2), list both in `config/deploy.yml` instead of `host:` so each
gets a certificate:

```yaml
proxy:
  ssl: true
  hosts:
    - www.example.com
    - example.com
```

and redirect one to the other in `frontend/next.config.ts`:

```ts
async redirects() {
  return [
    // example.com → www.example.com, keeping the path
    { source: "/:path*", has: [{ type: "host", value: "example.com" }],
      destination: "https://www.example.com/:path*", permanent: true },
  ];
},
```

Set `APP_URL` (and OAuth callback URLs) to the name you redirect to.

### The database

- **Where it is:** a `postgres:17` (or `mysql:8.4`) container on your server, storing its data in a
  directory there; the app reaches it by the container's name (`shop-db`).
- **Backups are up to you:** schedule `pg_dump` (or `mysqldump`), for example from cron on the server,
  and copy the dumps off it.
- **A managed database instead** (RDS, Neon, …): delete the `accessories: db:` block and set
  `DATABASE_URL` in `.env.production` and `.kamal/secrets` to the provider's URL
  (`DATABASE_URL=$DATABASE_URL`).
- **SQLite:** the file lives on a Docker volume shared by every role, so every role must stay on one
  server. PostgreSQL is recommended for production ([databases](database.md)).

### More servers

List more hosts under a role (for example two `web` and two `api` hosts). With several hosts, use a
shared cache (`config.cache.store = :redis`, `REDIS_URL`) so the cache and auth's rate limits are
shared, and move the database to a managed service or its own server.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `bin/deploy: Uncommitted changes` | Kamal deploys the last commit. Commit or stash your changes. |
| `No config/deploy.yml` | Run `gemstack generate deploy` first (step 1). |
| SSH fails: `Permission denied` or `Authentication failed` | Check `ssh <user>@<ip>` works from your terminal; set `ssh: user:` in `config/deploy.yml` when the user isn't `root`. |
| `Docker is not installed … can't be automatically installed` | The SSH user has neither root nor passwordless `sudo`. Install Docker on the server yourself, add the user to the `docker` group, and deploy again. |
| Pushing the image fails (`unauthorized`, `denied`) | `KAMAL_REGISTRY_PASSWORD` is missing or wrong, or the `image:` / `username:` doesn't match the account. For ghcr.io the token needs `write:packages`. |
| The image build fails in `bundle install` mentioning **checksums** | Run `bundle lock --add-checksums` and commit `Gemfile.lock`. |
| The build can't find GemStack gems (`path` in the Gemfile) | Apps created from a GemStack checkout point at it with a local path the image can't see. Use released gems, or `bundle cache --all` (the image copies `vendor/`). |
| The **web** role fails its health check on the first deploy | Apps generated before GemStack 0.4.3 have `primary_role: web`: set `primary_role: api` and add `proxy: true` under `servers: web:`, so the API starts first. |
| The **api** role fails its health check | Usually the database: run `bin/deploy logs` and look for connection errors; check `POSTGRES_PASSWORD` is set in `.env.production`. |
| The browser warns about the certificate | DNS doesn't point at the server yet, or port 80 is closed (Let's Encrypt checks over HTTP). Fix it, then reload; the proxy retries. |
| A setting is empty on the server | It's missing from one of the three places in [add a setting](#add-a-setting-your-app-reads-from-env), or `.env.production` doesn't contain it. `bin/deploy` prints which files it loaded. |
| A `NEXT_PUBLIC_*` value is missing in the browser | It wasn't in `.env.production` / `.env` when the image was built. Add it and deploy again. |
| Something else | `bin/deploy logs`, `bin/deploy app details`, and Kamal's [documentation](https://kamal-deploy.org/docs/). |

## How configuration reaches production

GemStack apps keep their settings in the root `.env` files (git-ignored), for the Ruby API and the
Next.js frontend alike. What reads what:

| Where | Files | Notes |
| --- | --- | --- |
| `gemstack dev`, tests | `.env.<env>.local`, `.env.local`, `.env.<env>`, `.env` | earlier files win |
| `bin/deploy` (your machine) | `.env.production.local`, `.env.production`, `.env` | never `.env.local` |
| The server (Kamal) | none — the image contains no `.env` | values arrive as environment variables, through `.kamal/secrets` and `env:` in `config/deploy.yml` |
| `next build` (in the image) | the `NEXT_PUBLIC_*` lines of `.env.production` / `.env` | passed as a build secret; public values only, compiled into the JavaScript |

In every case a real environment variable wins over the files. So the path of a secret is:
`.env.production` (your machine) → `bin/deploy` loads it → `.kamal/secrets` references it → Kamal sets
it on the containers listed under `env: secret:`.

## Without Kamal

The image (or the app itself) runs anywhere. A GemStack app is three processes:

```bash
# Ruby API
GEMSTACK_ENV=production GEMSTACK_API_PORT=4000 WEB_CONCURRENCY=2 bundle exec puma -C config/puma.rb

# Background jobs (any number of workers can share the queue)
GEMSTACK_ENV=production bundle exec gemstack jobs -c 10

# Next.js
cd frontend && npm ci && npm run build && npm start
```

Run `GEMSTACK_ENV=production bundle exec gemstack db:migrate` on each release, before starting the new
API processes. Outside Docker, both the API and Next.js read the root `.env.production` / `.env` on the
server (real environment variables win), and `NEXT_PUBLIC_*` values must be there when
`npm run build` runs. Next.js's standalone server reads them through a preload:
`npm run start:standalone` in `frontend/`.

From the Docker image, the commands are
`node -r ./frontend/lib/gemstack/root-env.cjs frontend/server.js`, `bundle exec puma -C config/puma.rb`
and `bundle exec gemstack jobs`. Presets for container platforms (Heroku, Fly.io, Render, Railway) are
planned.

### How `/api` reaches Ruby

The browser always calls `/api/...` on the site's own origin, so one of these must route it:

1. **A reverse proxy** (what Kamal does): kamal-proxy, Caddy, nginx or a platform's router sends
   `/api/*` to Puma and everything else to Next.js. For realtime behind nginx, set
   `proxy_http_version 1.1`, the `Upgrade` and `Connection "upgrade"` headers and a
   `proxy_read_timeout` above 15 s for `/api/realtime` ([realtime](realtime.md)).
2. **Next.js rewrites:** set `GEMSTACK_API_URL` (e.g. `http://api.internal:4000`) **when building**
   the frontend, and Next.js proxies `/api/*` to Ruby — HTTP, Server-Sent Events and WebSockets. Deploy
   Next.js publicly and the API privately.
3. **Separate domains** (`api.example.com`): build the frontend with
   `NEXT_PUBLIC_GEMSTACK_API_URL=https://api.example.com` and allow the site in
   `config/environments/production.rb`: `config.http.cors.origins = ["https://example.com"]`.

## Production checklist

- `gemstack doctor --production` passes where the production values are — on a Kamal server, inside
  the api container: `bin/deploy app exec --roles=api "bundle exec gemstack doctor --production"`.
- `SECRET_KEY_BASE` is set (`openssl rand -hex 64`) and **never changes** — signed links and sessions
  depend on it.
- The database is backed up, and the backups are copied off the server.
- Apps with auth or mailers: `SMTP_URL`, `MAIL_FROM` and `APP_URL` are set; a jobs worker runs (emails
  are sent from jobs); call `GemStack::Auth.cleanup!` daily.
- Apps with file uploads: storage is configured for production ([storage](storage.md)).
- Health check: `GET /api/health` returns `200 {"status":"ok"}`.
- Logs: each line on stdout is a JSON object (`level`, `msg`, `id`); `bin/deploy logs` follows them.
- Sizing: `WEB_CONCURRENCY` ≈ CPU cores and `GEMSTACK_MAX_THREADS` 3–5; database connections needed per
  host = `WEB_CONCURRENCY × GEMSTACK_MAX_THREADS`. YJIT is on automatically.
- Production defaults need no setup: HTTPS-only cookies, HSTS, JSON logs with request IDs, no exception
  details in responses, Brotli/gzip compression.
