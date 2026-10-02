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
responses, eager loading, HSTS on HTTPS requests, `.env` files not loaded
(use real environment variables for secrets).

## Kamal

```bash
gemstack generate deploy
```

Generates a complete Kamal deployment configuration:
- Dockerfile (multi-stage build for Ruby API and Next.js frontend)
- config/deploy.yml (Kamal configuration with web, API, and optional jobs roles)
- .kamal/secrets (references to environment variables for sensitive data)
- bin/docker-entrypoint (handles database migrations on startup)
- .dockerignore (optimizes Docker build context)

Nothing is deployed yet — the files are yours to review, customize, and use.

The images run as a non-root user, contain no `.env` files or secrets (all
configuration comes from environment variables at runtime), and the API image
runs database migrations before starting the server.

Try production mode locally with Kamal:

```bash
export SECRET_KEY_BASE=$(openssl rand -hex 64) POSTGRES_PASSWORD=$(openssl rand -hex 16)
bundle install
bundle exec kamal setup
```

With a real domain, Kamal will automatically obtain and manage Let's
Encrypt certificates via kamal-proxy.

> Apps created from a GemStack **checkout** reference it with an absolute
> `path` in the Gemfile, which the image can't see. Run `bundle cache --all`
> (the Dockerfile copies `vendor/`), or use released gems.

### Platforms

Kamal supports deployment to any VM or cloud provider with SSH access and Docker:

| Platform | How |
| --- | --- |
| **Generic VM/VPS** | `bundle exec kamal setup` then `bundle exec kamal deploy` |
| **AWS EC2** | SSH to instance, run `bundle exec kamal setup`, then `bundle exec kamal deploy` |
| **Google Compute Engine** | SSH to instance, run `bundle exec kamal setup`, then `bundle exec kamal deploy` |
| **DigitalOcean Droplets** | SSH to droplet, run `bundle exec kamal setup`, then `bundle exec kamal deploy` |
| **Linode** | SSH to instance, run `bundle exec kamal setup`, then `bundle exec kamal deploy` |
| **Bare metal servers** | SSH to server, run `bundle exec kamal setup`, then `bundle exec kamal deploy` |

## Choose how `/api` reaches Ruby

The browser always calls same-origin `/api/...`, so pick one:

### 1. Reverse proxy (built-in with Kamal)

Kamal includes kamal-proxy which automatically handles SSL termination and
proxies `/api/*` to your Ruby API and everything else to your Next.js frontend.
No additional configuration needed.

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

Server-Sent Events work through rewrites; WebSockets need option 1 (reverse proxy).

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
- Add `gem "brotli"` for Brotli compression; with a compressing CDN/proxy in front, either is fine
  (GemStack never re-compresses encoded responses).
- Several processes/hosts? Kamal handles this natively through role-based configuration.
- Realtime (SSE) works through Next.js rewrites and Kamal's proxy; see docs/realtime.md.
- `SECRET_KEY_BASE` (`openssl rand -hex 64`) — needed by storage signatures and any module using
  `GemStack.key_for`; keep it stable across deploys.
- With auth: `SMTP_URL`, `MAIL_FROM` and `APP_URL` (the frontend's public URL, for email links); run a
  jobs worker (emails are sent from jobs); Kamal handles HTTPS/TLS termination; call
  `GemStack::Auth.cleanup!` daily; use Kamal's secrets management for API credentials.
- With storage: `STORAGE_SERVICE=s3`, `S3_BUCKET`, `AWS_REGION` (+ credentials), `gem "aws-sdk-s3"`, and
  a bucket CORS rule allowing `PUT` from your site (docs/storage.md).
- Health check: `GET /api/health` → `200 {"status":"ok"}`.
- Collect stdout: each line is a JSON object with `level`, `msg`, `id`.
