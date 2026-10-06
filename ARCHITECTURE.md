# GemStack Architecture

This document describes how GemStack is put together: its module boundaries,
the lifecycle of a request, and how the Next.js frontend and Ruby backend are
presented as a single application.

---

## 1. Shape of a GemStack application

```text
                     Browser
                        │
                        ▼
                 localhost:3000            (one public origin: HTTP and WebSockets)
                        │
                 GemStack Gateway          (dev: gemstack dev; prod: kamal-proxy or your reverse proxy)
                  /            \
      everything else          /api/*  (incl. the /api/realtime WebSocket)
                /                \
          Next.js (TS)       GemStack Ruby API (Rack + Puma)
       internal port          internal port
                                   │
                     SQLite · PostgreSQL · MySQL
```

A generated project:

```text
myapp/
├── Gemfile                  # a normal Bundler Gemfile — any gem works
├── config.ru                # Rack entry point (Puma, or any Rack server)
├── config/
│   ├── app.rb               # GemStack.configure { ... } — the one config file
│   ├── routes.rb            # API routes
│   ├── puma.rb              # server tuning (threads/workers from ENV)
│   └── environments/        # optional per-env overrides (development.rb, ...)
├── app/
│   └── controllers/
│       └── application_controller.rb
├── test/                    # Minitest + rack-test
├── frontend/                # a standard Next.js App Router project (TypeScript)
│   ├── app/                 # layout.tsx, page.tsx, providers.tsx
│   ├── lib/gemstack/        # vendored API client runtime (owned by the app)
│   ├── next.config.ts       # /api rewrites for gateway-less production
│   └── package.json
├── .env.example
└── README.md
```

`app/` subdirectories (`models/`, `serializers/`, `services/`, `policies/`,
`jobs/`) are autoloaded when they exist. The project contains no business
resources: no User, no auth, no CRUD — only infrastructure.

---

## 2. Gems and modules

GemStack is published as four gems, developed together in this repository and
released with one version:

| Gem | What it is | Dependencies |
|---|---|---|
| `gemstack` | the framework: every module below except auth and realtime, the CLI code and generators | rack, json, sequel, mail, erubi, thor, puma, zeitwerk, bigdecimal, gemstack-cli |
| `gemstack-cli` | only the `gemstack` executable (its code is `gemstack/cli` in the gemstack gem) | none |
| `gemstack-auth` | authentication and policies — `gemstack add auth` | gemstack, argon2 (native) |
| `gemstack-realtime` | WebSockets and Server-Sent Events: channels, presence, browser messages — `gemstack add realtime` | gemstack, nio4r (native) |

Auth and realtime are separate gems only because of their native
dependencies. The names `gemstack-core`, `-cache`, `-schema`, `-http`, `-db`,
`-jobs`, `-mail`, `-storage`, `-contract` and `-dev` were separate gems until
0.3.0; their last versions are shims that depend on `gemstack` and load the
module.

Inside the `gemstack` gem, each module is a directory under `lib/gemstack/`,
with one-directional dependencies:

```text
  app  (lib/gemstack.rb: Application, boot, autoload, reloading, testing)
   │
   ├── cli ── dev ── contract          `gemstack` command, gateway + supervisor, TypeScript/OpenAPI
   │
   ├── realtime, auth                  (separate gems)
   │
   ├── storage ── mail ── jobs ── db   opt-in: require "gemstack/db" (…) in config/app.rb
   │
   └── http ── schema ── cache ── core (core: Ruby's standard library only)
```

Rules (enforced by `gems/gemstack/test/app/architecture_test.rb`, on the
require graph):

1. **`core` uses only Ruby's standard library** and never loads another module.
2. Requires only point down the order
   `core → cache → schema → http → db → jobs → mail → storage → realtime → auth → contract → dev → cli → app`.
3. **`db` never loads `http`**; it gives database errors their HTTP meaning
   through core's `ErrorMapping`.
4. **`require "gemstack"` loads only core, cache, schema, http, contract and
   dev.** Apps switch on db, jobs, mail and storage with `require
   "gemstack/<module>"` in `config/app.rb` (`gemstack new` writes the ones it
   uses; `gemstack add storage` adds its line).
5. Modules plug in by registering config namespaces and `Plugins` hooks.

| Module | Responsibility |
|---|---|
| `core` | `GemStack` namespace, settings DSL, environment, `.env` loading, logger, errors, `ErrorMapping`, inflector, plugins |
| `cache` | `GemStack.cache`: memory (LRU/TTL), null, Redis stores |
| `schema` | shared `Types`, request `Schema`s, `Serializer`s (compiled plans) |
| `http` | Rack request/response, router, middleware, controllers (`accepts`/`input`/`returns`, serializer lookup), params, JSON codec, error rendering |
| `db` | Sequel connection + pool for SQLite/PostgreSQL/MySQL, `config/database.yml`, portable migration types, `GemStack::Model`, error mapping, migrations, db tasks, test support |
| `jobs` | `GemStack::Job`, adapters (database/async/inline/test/sidekiq), worker, test helpers |
| `mail` | `GemStack::Mailer`, ERB templates (HTML-escaped), :smtp/:log/:test delivery, `deliver_later` job, test helpers |
| `storage` | `GemStack::Storage`: disk and S3 services, signed URLs, direct uploads, disk endpoint, test helpers |
| `realtime` *(gem)* | `GemStack.broadcast`, channels, WebSocket and SSE endpoint (hijack + nio4r), presence, brokers, test helpers |
| `auth` *(gem)* | Argon2id passwords, DB sessions (cookie), API/reset/verification tokens, controller helpers, CSRF origin check, `rate_limit`, `GemStack::Policy` |
| `contract` | contract IR from routes/schemas/serializers → TypeScript types + clients, OpenAPI 3.1 |
| `dev` | dev gateway, process supervisor, file watcher, background contract regeneration, toolchain detection |
| `cli` | generators, `add`, `db:*`, `jobs`, `contract`, `doctor` — run by the `gemstack` executable from gemstack-cli |
| app | `GemStack::Application`: boot, Zeitwerk autoloading, reloading, testing helpers |

---

## 3. Configuration and extension mechanism

### 3.1 One configuration object

```ruby
# config/app.rb
GemStack.configure do |config|
  config.name = "shop"
  config.http.api_path = "/api"
  config.http.max_body_size = 2 * 1024 * 1024
  config.http.middleware.use MyMiddleware
  config.logger.level = :debug
end
```

- `GemStack.config` is a tree of `GemStack::Settings` objects. Each gem
  **registers its own namespace** (`config.http`, later `config.db`,
  `config.jobs`, ...), so core does not need to know about modules.
- Every setting has a default. Settings can be derived from ENV at read time
  (`default: -> { ENV.fetch("PORT", 3000).to_i }`).
- Unknown setting names raise immediately (typos fail fast, with suggestions).
- `config/environments/<env>.rb` is loaded after `config/app.rb`, for
  per-environment overrides.

### 3.2 The four levels of customisation

Every subsystem is designed so a developer can go further down this list
without forking GemStack:

1. **Use the default** — do nothing.
2. **Configure** — change a setting (`config.http.api_path = "/v1"`).
3. **Swap the implementation** — pass an object honouring a small interface
   (`config.http.json = MyCodec`, `config.jobs.adapter = :sidekiq`,
   `config.cache.store = MyStore.new`).
4. **Replace the layer** — GemStack's HTTP app is a plain Rack app, so any
   Rack middleware or even another Rack framework can be mounted; the frontend
   is a plain Next.js project; the Gemfile is plain Bundler.

### 3.3 Adapters

Swappable subsystems are defined by a *duck-typed interface* documented in the
module (e.g. a JSON codec responds to `dump(obj)` and `load(string)`). A setting
may hold either a symbol naming a built-in adapter or an object. Adapters are
resolved at boot, not per request.

### 3.4 Plugins

`GemStack::Plugins.register(:name) { |app| ... }` lets a gem hook the boot
sequence (after configuration, before the app is frozen). Future optional
modules (db, jobs, realtime) use this to add middleware, config and shutdown
hooks without the umbrella knowing about them in advance.

---

## 4. Request lifecycle

```text
Puma ──▶ Rack env
  │
  ▼
Middleware stack (config.http.middleware — ordered, editable)
  1. RequestId        assign / propagate X-Request-Id (validated, length-limited)
  2. RequestLogger    one structured log line per request, written when the body closes
     Compression      br/gzip negotiation for compressible bodies ≥ 1 KB (D-033)
  3. ErrorHandler     exception boundary → JSON error; hides internals in production
     [dev] Reloader   reload app code + routes when files change (inside ErrorHandler,
                      so a SyntaxError while reloading becomes a JSON 500)
  4. SecurityHeaders  nosniff, frame-deny, referrer-policy, COOP, strict CSP; HSTS on https in production
  5. Cors             no-op until config.http.cors.origins is set
  6. BodyLimit        413 if Content-Length or streamed body exceeds max_body_size
  7. HealthCheck      GET <api_path>/health → 200 {"status":"ok"} (skips the router)
  8. ETags            Rack::ConditionalGet + Rack::ETag: weak ETags, 304 Not Modified (D-036)
  │
  ▼
Router  ── static-segment hash lookup, then dynamic segments; 404/405 with Allow
  │
  ▼
Controller#dispatch
  - builds Params (path + query + JSON/form body; parsed lazily, depth/size limited)
  - runs `before` callbacks (may halt by rendering)
  - calls the action
  - `rescue_from` handlers map domain errors to responses
  - `render value, status:` → JSON via the configured codec
  │
  ▼
Rack response triple  [status, headers, body]
```

Performance-relevant properties of this design:

- The middleware stack is **compiled once** at boot into a nested Rack app —
  no per-request stack building.
- The router **pre-compiles** routes: a hash keyed by `[verb, path]` for fully
  static routes (O(1)), and a per-verb segment trie for dynamic routes. Route
  helpers resolve controllers once (per reload in development).
- JSON bodies are parsed only when `params` or `request.json` is first used.
- Controllers are instantiated per request (cheap, no shared mutable state).

### Errors

All errors produce the same JSON envelope:

```json
{
  "error": { "code": "not_found", "message": "Not Found", "request_id": "c0ffee..." },
  "errors": { "name": ["is required"] }
}
```

`errors` (field → messages) appears only for validation failures. In
development, unexpected exceptions also include `exception` and `backtrace`;
in production they never do.

---

## 5. Single-origin development architecture

`gemstack dev` starts these under one supervisor. Only the gateway listens on
the public port; Next.js and Puma listen on loopback ports the browser never sees:

```text
gemstack dev
  ├── Gateway        TCP listener on :3000 (PORT)       — in-process thread pool
  ├── Ruby API       bundle exec puma -b tcp://127.0.0.1:<free port>
  ├── Next.js        next dev -H 127.0.0.1 -p <free port>
  └── Jobs worker    bundle exec gemstack jobs           — when the app uses the database queue
```

- The internal ports are chosen automatically (free ephemeral ports). The
  developer never sees or configures them.
- The **gateway** reads each request's head, chooses an upstream by path
  prefix (`api_path` → Ruby, everything else → Next.js), adds
  `X-Forwarded-For/Proto/Host`, then **pipes raw bytes** in both directions.
  Because it proxies at the byte level after routing, it transparently
  supports request/response streaming and WebSocket upgrades: Next.js HMR
  (`/_next/…`) goes to Next.js, the realtime WebSocket (`/api/realtime`) to Puma.
- To keep routing correct per request the gateway uses one upstream
  connection per request (`Connection: close` towards the upstream). This is a
  deliberate dev-only simplicity trade-off; localhost connection setup is ~0.1ms.
- When an upstream is still booting or has crashed, the gateway responds with
  a friendly auto-refreshing page (HTML) or a JSON `503 upstream_unavailable`
  (API paths) instead of a connection error.
- The supervisor prefixes and colours each process's output
  (`api │`, `next │`, `gateway │`), restarts the Ruby process when
  `config/**` or `Gemfile.lock` changes, and shuts everything down on Ctrl-C.
- Code in `app/` and `config/routes.rb` reloads **in-process** without a
  restart (Zeitwerk + a reader/writer interlock so reloads never race requests).

### How the frontend reaches the API

- **Browser code** calls relative URLs: `fetch("/api/products")`. Same origin,
  so no CORS and no API URL configuration.
- **Server Components / Route Handlers** run in the Next.js process where
  relative URLs do not exist. The supervisor injects `GEMSTACK_API_URL`
  (the internal Ruby URL) into the Next.js environment; the vendored client
  (`frontend/lib/gemstack/client.ts`) uses it automatically on the server.

## 6. Production architecture — see docs/deployment.md

Default: one public origin, owned by a proxy; Next.js and Puma run internally.

```text
https://example.com ──▶ kamal-proxy (gemstack generate deploy) / reverse proxy
                         ├── /api/*  → Ruby (puma, config/puma.rb) — HTTP and the realtime WebSocket
                         └── /*      → Next.js (standalone server)
```

Supported shapes, in order of preference:

1. **A proxy routing by path** — kamal-proxy (what `gemstack generate deploy`
   sets up), Caddy, nginx, Traefik or a platform router. WebSocket upgrades
   go straight to Puma.
2. **Next.js rewrites** — the generated `next.config.ts` rewrites `/api/:path*`
   to `GEMSTACK_API_URL`. Deploy Next.js publicly and the Ruby API privately;
   still single origin, no extra proxy. `next start` passes WebSocket upgrades
   on rewrites; where something in front doesn't, the realtime client falls
   back to Server-Sent Events.
3. **Separate domains** (`api.example.com`) — set `NEXT_PUBLIC_GEMSTACK_API_URL`
   on the frontend and `config.http.cors.origins` on the backend (the realtime
   Origin check accepts those origins too).

---

## 7. Resource generation

```text
gemstack generate resource Product name:string price:decimal active:boolean [--api-only|--frontend-only|--crud]
          │
          ▼
  ResourceSpec (name, fields, options)   ← from args, or asked interactively
          │
          ├──▶ backend generators: migration, model, serializer, controller, routes, policy?, tests
          └──▶ frontend generators: pages, components (form/table/card)
                                   (types + API client come from the contract generator, not templates)

  frontend parts: lib/queries/<plural>.ts (TanStack Query hooks), components/<plural>/{Form,Table,Card}.tsx,
                  app/<plural>/{page,new/page,[id]/page,[id]/edit/page}.tsx  — only those the actions need
```

- Generators are small classes with a `ResourceSpec` input and a list of
  templates; each is selectable and **overridable**: an app can place its own
  templates in `lib/templates/gemstack/<generator>/` and they win.
- Generators are idempotent where practical (routes insertion checks for an
  existing entry; files are never silently overwritten).
- Resource *patterns* (`crud`, `read-only`, `singleton`, `action`) are just
  different generator compositions over the same spec.

## 8. API contract & TypeScript generation

Source of truth is the **backend**:

```text
Model fields (field :price, :decimal) ──▶ Product.input_schema ─┐
                                      └─▶ serializer types ───────┤
Controller `accepts` / `returns`                                  ├──▶ Contract IR ──┬──▶ frontend/lib/api/generated/types.ts
Route table (verbs, paths, controllers) ──────────────────────────┘ (gemstack       ├──▶ frontend/lib/api/generated/<resource>.ts
                                                                     contract)       └──▶ openapi.json (OpenAPI 3.1)
```

- Types are derived from serializers (what the API actually emits), not from
  database columns, so hidden fields never leak into the frontend types.
- Ruby → TS mapping is explicit and documented (`decimal` → `string` by
  default to preserve precision; `datetime` → ISO `string`).
- Response types follow conventions (`index → [ProductSerializer]`, ...) and
  can be declared with `returns`.
- Generated files carry a header and are regenerated by `gemstack contract`,
  by `generate resource`, and in the background by `gemstack dev` when backend
  files change. Only changed files are rewritten; hand-written code lives next
  to them, never inside them.
- The generator is Ruby — no Node dependency to produce TypeScript.

## 9. Background jobs — see docs/background-jobs.md

```ruby
class SendWelcomeEmail < GemStack::Job
  queue :mailers
  retry_on Net::ReadTimeout, attempts: 5
  def perform(user_id) = ...
end
SendWelcomeEmail.perform_later(user.id)
```

```text
perform_later ──▶ Arguments.dump (JSON only) ──▶ adapter.enqueue
                                                  ├─ :postgres  INSERT gemstack_jobs + NOTIFY (in the caller's transaction)
                                                  ├─ :async     in-process schedule (after commit)
                                                  ├─ :sidekiq   Sidekiq::Client.push (after commit)
                                                  ├─ :test      recorded for assertions
                                                  └─ :inline    run now

gemstack jobs (Worker) ── N threads: claim (FOR UPDATE SKIP LOCKED) → Executor.execute → settle
                      ├── LISTEN thread: NOTIFY → wake idle threads
                      └── reaper: release locks older than lock_timeout
Executor (shared by all adapters): performed | retry (backoff) | discarded | failed → events + logs
```

- `Job` is a thin class API (`queue`, `priority`, `retry_on`, `discard_on`,
  `perform_later`, `set`, `perform_now`); adapters are swappable.
- Every app with a database gets the `gemstack_jobs` table from `gemstack new`.
- `gemstack dev` runs a worker when the app uses the database queue, and
  restarts it when `app/` changes. Work is asynchronous only through
  `perform_later`; the adapter is `config.jobs.adapter`.

## 10. Realtime — see docs/realtime.md

```text
GemStack.broadcast(channel, event, data)
   │  Serializer.render(data) → Message {id, channel, event, data}
   ▼
broker.publish ── :postgres NOTIFY (transactional) | :redis PUBLISH | :memory | :test
   ▼  (every API process: one LISTEN / SUBSCRIBE thread)
Hub.deliver ── channel → connections, bounded replay history; presence announcements → Presence
   ▼
WebSocket::Connection ◀── Streamer: one nio4r loop per process (reads frames, non-blocking
   │                       writes, pings, drops silent/slow clients)
   └─ subscribe / unsubscribe / message ──▶ Dispatcher (thread pool, per-connection order,
                                            application interlock) → config/channels.rb
GET /api/realtime + Upgrade ── Middleware: handshake, Origin check, identify, Rack full hijack
```

- Optional: added with `gemstack add realtime`. Without it there's no
  middleware, no threads, no client code.
- Two transports, same features (`config.realtime.transports`): WebSocket —
  framing (RFC 6455) in `WebSocket::Codec`, the JSON protocol in
  `WebSocket::Connection` — and Server-Sent Events (`Connection`, a `GET`
  stream per set of channels, browser messages as `POST`s). Both register with
  the same `Hub` and `Presence`.
- `config/channels.rb`: `identify` (per connection), `channel` rules
  (deny by default, `presence: true`), `receive` handlers (browser → server).
- Presence is replicated through the broker with periodic refreshes; entries
  from a process that stops refreshing lapse.
- The browser client (`frontend/lib/gemstack/realtime.ts`) keeps one
  connection per tab (WebSocket by default; Server-Sent Events when set, or
  when a WebSocket can't be opened), resubscribes with the last event id after
  reconnecting (backoff with jitter; `offline` while the browser is), and
  exposes `useRealtime`, `usePresence`, `useRealtimeStatus` and `realtime.send`
  — the same API on either transport.

## 11. Performance strategy

Principles: measure, then optimise; defaults must be fast without being clever.

| Area | Decision (measured — docs/performance.md) |
|---|---|
| Runtime | Ruby 4; YJIT on in production (+27% req/s, D-039) |
| Server | Puma, threads/workers from ENV, `preload_app!`, DB disconnect before fork |
| Middleware | compiled once; 9 small middlewares; ETags ≈ 2 µs |
| Routing | static hash + dynamic segment trie (0.27 µs / 1.85 µs) |
| JSON | stdlib `JSON::Coder`; Oj adapter available but slower (D-037) |
| Serialization | compiled per-serializer plans (3× faster, D-038) |
| Params | lazy body parsing, size/depth limits |
| Compression | Brotli 4 / gzip 4 ≥ 1 KB, streaming-aware (D-033) |
| Pagination | `{ data, meta }` envelope by default for generated `index` (D-034) |
| DB | Sequel pool sized to threads, lazy connect, slow-query warnings |
| Caching | HTTP: ETag/304 + `stale?`; app: `GemStack.cache` memory/Redis (D-035) |

Benchmarks live in `benchmarks/` (plain Ruby scripts using `Benchmark` and
`GC.stat` allocation counts) and results are recorded in `docs/performance.md`.

## 12. Security defaults

Always on: request IDs validated, request body size limit, JSON parse
depth limit, security headers, production error pages without internals,
parameter filtering in logs (`password`, `token`, `secret`, ... configurable),
CORS off by default (same-origin needs none) with explicit allow-listing when
enabled. Opt-in modules add Argon2id passwords, database sessions in
HttpOnly/SameSite cookies (`__Host-`/Secure in production), digest-only token
storage, cross-site request refusal via `Sec-Fetch-Site`/`Origin`,
`rate_limit`, deny-by-default policies, signed storage URLs, and
`SECRET_KEY_BASE` with per-purpose keys (`GemStack.key_for`) — see
docs/authentication.md, docs/authorization.md and docs/storage.md.
