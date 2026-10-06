# Deployment

A GemStack app is two processes:

```bash
# Ruby API (Puma, config/puma.rb)
GEMSTACK_ENV=production GEMSTACK_API_PORT=4000 WEB_CONCURRENCY=2 bundle exec puma -C config/puma.rb
# or: gemstack server -e production -p 4000

# Next.js
cd frontend && npm ci && npm run build && npm start
```

Run background job workers as a third process type (scale them
independently; any number can share the queue):

```bash
GEMSTACK_ENV=production DATABASE_URL=… bundle exec gemstack jobs -c 10
```

Run migrations on each release, before starting the new API processes:

```bash
GEMSTACK_ENV=production DATABASE_URL=… bundle exec gemstack db:migrate
```

Production defaults: JSON logs with request IDs, no exception details in
responses, eager loading, HSTS on HTTPS requests.

### Environment and `.env`

One `.env` at the app root configures both processes, in every environment: the
API loads `.env.production.local`, `.env.local`, `.env.production` and `.env`
(earlier files win), and `frontend/next.config.ts` loads the same files for
`next build` and `next start`. Real environment variables always win, so a
platform's settings override the files.

- `NEXT_PUBLIC_*` values are compiled into the JavaScript at **build** time: have
  them in the root `.env` (or the environment) where `npm run build` runs, and
  rebuild after changing one.
- Next.js's standalone server (`node frontend/server.js`, used by the Docker
  image) doesn't run `next.config.ts`: its server-side variables come from the
  environment, as in the Kamal setup below.
- With Kamal, the image contains no `.env`: runtime settings come from
  `config/deploy.yml` (`env:`) and `.kamal/secrets`. For the frontend build,
  `.kamal/secrets` passes the `NEXT_PUBLIC_*` lines of the root `.env.production`
  and `.env` as a build secret (`GEMSTACK_PUBLIC_ENV`), mounted for `next build`
  only — public values, never stored in the image, nothing else from the file.

## Kamal

```bash
gemstack generate deploy
bundle install                # adds the kamal gem (development group)
```

writes a [Kamal](https://kamal-deploy.org) setup for any server you can reach over SSH (a VPS, a cloud VM,
bare metal):

| File | What it is |
| --- | --- |
| `Dockerfile` | one image for every process: the Ruby API, the jobs worker and Next.js's standalone server |
| `config/deploy.yml` | roles **web** (Next.js), **api** (Puma) and **jobs** (worker); kamal-proxy; database accessories |
| `.kamal/secrets` | *references* to secrets (`SECRET_KEY_BASE=$SECRET_KEY_BASE`), never their values; committed to git |
| `bin/docker-entrypoint` | the api role applies pending migrations before it starts serving |
| `.dockerignore` | keeps `.git`, `.env*`, `.kamal/`, keys and `node_modules` out of the image |

How requests flow: kamal-proxy terminates HTTPS (Let's Encrypt) for your domain, sends `/api/*` to the
api role and everything else to the web role — one origin, as in development. Next.js Server Components
reach the API directly through the `<service>-api` network alias. Deploys are zero-downtime: the proxy
switches to new containers once their health checks (`/` and `/api/health`) pass.

The images run as a non-root user and contain no `.env` files or secrets: everything comes from
environment variables at runtime, except the frontend's `NEXT_PUBLIC_*` values, which `next build`
compiles in from the root `.env` ([environment](#environment-and-env)). The PostgreSQL or MySQL accessory (from `config/database.yml`) runs
on the same server; Redis is added when realtime needs it; SQLite gets a persistent volume.

### First deploy

1. **A server** with SSH access as `root` (or set `ssh: user:`), ports 80 and 443 open. Kamal installs
   Docker on it during setup.
2. **A domain** whose DNS points at the server (Let's Encrypt checks it).
3. **Edit the `CHANGE` lines** in `config/deploy.yml`: the server IP (every role and accessory), the
   domain (`proxy: host:` and `APP_URL`), and your registry user.
4. **A container registry.** Docker Hub by default: create an access token and use it as
   `KAMAL_REGISTRY_PASSWORD`. For GitHub's registry set `registry: server: ghcr.io`. With a single server
   you can skip the account entirely with `registry: server: localhost:5555` — Kamal pushes the image to
   the server over SSH.
5. **Set the secrets** that `.kamal/secrets` references, in your shell or a password manager
   (`$(kamal secrets fetch …)`):

   ```bash
   export KAMAL_REGISTRY_PASSWORD=…                           # the registry token
   export SECRET_KEY_BASE=$(openssl rand -hex 64)             # keep it: the same value on every deploy
   export POSTGRES_PASSWORD=$(openssl rand -hex 16)           # PostgreSQL; MYSQL_PASSWORD for MySQL
   export SMTP_URL=smtp://user:password@smtp.example.com:587  # leave empty until you send email
   ```

6. **Deploy** from your own machine (Kamal connects to the server; nothing is installed by hand there):

   ```bash
   bundle exec kamal setup      # first time: Docker, kamal-proxy, the database, then the app
   bundle exec kamal deploy     # every deploy after that
   ```

Run `gemstack doctor` before committing: it fails if `.kamal/secrets` contains a value instead of a
reference.

### Day to day

```bash
bundle exec kamal deploy       # build, push and switch with zero downtime
bundle exec kamal logs         # follow the logs (alias in config/deploy.yml)
bundle exec kamal console      # gemstack console on the server
bundle exec kamal migrate      # gemstack db:migrate (deploys run it already)
bundle exec kamal shell        # a shell in the api container
bundle exec kamal rollback VERSION
```

Notes:

- **One HTTPS role per domain.** `/api` shares the web role's certificate, so the api role has
  `ssl: false` — that is expected, requests to `/api` are still HTTPS. It also has
  `forward_headers: false`, so kamal-proxy sets `X-Forwarded-For`/`-Proto` itself instead of trusting
  values sent by clients (IP-based rate limits rely on it).
- **Back up the database.** The accessory keeps its data in a directory on the server; schedule dumps.
- **Several servers?** List more hosts under a role. Use `config.cache.store = :redis` (`REDIS_URL`) so
  the cache and auth's rate limits are shared, and move the database to a managed service or its own host.
  SQLite needs every role on one server.

> Apps created from a GemStack **checkout** reference it with an absolute
> `path` in the Gemfile, which the image can't see. Run `bundle cache --all`
> (the Dockerfile copies `vendor/`), or use released gems.

### Hosting platforms

Kamal works with any provider that gives you a Linux server with SSH: Hetzner, DigitalOcean Droplets,
AWS EC2, Google Compute Engine, Linode, or your own hardware. You always run `kamal` from your machine
(or CI), never on the server. Presets for platforms that run containers for you (Heroku, Fly.io,
Render, Railway) are planned; until then the image runs any role through its command
(`node frontend/server.js`, `bundle exec puma -C config/puma.rb`, `bundle exec gemstack jobs`) and
the options below cover how `/api` reaches Ruby there.

## Choose how `/api` reaches Ruby

The browser always calls same-origin `/api/...`, so pick one:

### 1. Reverse proxy (what Kamal does)

kamal-proxy, Caddy, nginx or a platform's router sends `/api/*` to Puma and everything else to
Next.js. With Kamal this is already configured.

### 2. Next.js rewrites (alternative approach)

If not using Kamal's proxy, the generated `next.config.ts` proxies `/api/*` to
`GEMSTACK_API_URL` when it is set. Deploy Next.js publicly and the API privately:

```bash
cd frontend
GEMSTACK_API_URL=http://api.internal:4000 npm run build   # rewrites are fixed at build time
GEMSTACK_API_URL=http://api.internal:4000 npm start       # also used by Server Components
```

> **Set `GEMSTACK_API_URL` at build time.** Next.js evaluates `rewrites()` during
> `next build`; changing it only at runtime does not change the rewrite target.

Realtime works through the rewrites: `next start` (Next.js 16) passes WebSocket upgrades
on rewrites to the API, and Server-Sent Events stream through as plain HTTP. If something in
front of Next.js drops WebSocket upgrades, the client (in its default `auto` mode) falls back to
Server-Sent Events by itself — see docs/realtime.md.

### 3. Separate domains

If the API must live on `api.example.com`:

```ruby
# config/environments/production.rb
config.http.cors.origins = ["https://example.com"]
```

and build the frontend with `NEXT_PUBLIC_GEMSTACK_API_URL=https://api.example.com`.

## Checklist

- Run `gemstack doctor --production` with the production environment variables.

- `GEMSTACK_ENV=production` and `DATABASE_URL` for the API; `db:migrate` on release.
- Database connections (PostgreSQL/MySQL): `WEB_CONCURRENCY × GEMSTACK_MAX_THREADS` per host (pool per worker).
- For SQLite: Kamal generates a volume definition to persist the database file.
- SSL/TLS is handled automatically by kamal-proxy (Let's Encrypt) or can be brought externally.
- `WEB_CONCURRENCY` ≈ CPU cores, `GEMSTACK_MAX_THREADS` 3–5.
- YJIT is enabled automatically in production (`config.jit`); nothing to set.
- Brotli comes from `gem "brotli"` (in new apps' Gemfile; gzip otherwise); with a compressing CDN/proxy in front, either is fine
  (GemStack never re-compresses encoded responses).
- Several processes/hosts? Use `config.cache.store = :redis` (`gem "redis-client"`, `REDIS_URL`).
- Realtime is `/api/realtime` (WebSocket, or Server-Sent Events as the fallback): kamal-proxy routes
  it to the api role with the rest of `/api` (verified). Behind nginx, set `proxy_http_version 1.1`,
  `Upgrade` and `Connection "upgrade"` for that path, and `proxy_read_timeout` above the 15 s ping
  (the stream sends `X-Accel-Buffering: no`, so nginx doesn't buffer it); see docs/realtime.md.
- `SECRET_KEY_BASE` (`openssl rand -hex 64`) — needed by storage signatures and any module using
  `GemStack.key_for`; keep it stable across deploys.
- With auth: `SMTP_URL`, `MAIL_FROM` and `APP_URL` (the frontend's public URL, for email links); run a
  jobs worker (emails are sent from jobs); serve over HTTPS (the session cookie is `Secure`); call
  `GemStack::Auth.cleanup!` daily; use the Redis cache store with several hosts so rate limits are shared.
- With storage: `STORAGE_SERVICE=s3`, `S3_BUCKET`, `AWS_REGION` (+ credentials), `gem "aws-sdk-s3"`, and
  a bucket CORS rule allowing `PUT` from your site (docs/storage.md).
- Health check: `GET /api/health` → `200 {"status":"ok"}`.
- Collect stdout: each line is a JSON object with `level`, `msg`, `id`.
