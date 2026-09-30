# Architecture (overview)

The full design is in [ARCHITECTURE.md](../ARCHITECTURE.md). This page is the
short version for application developers.

## Gems

| Gem | You use it for |
|---|---|
| Module (in the `gemstack` gem) | What you use from it |
|---|---|
| `core` | `GemStack.configure`, `GemStack.env`, `GemStack.logger`, errors (`GemStack::NotFound`, ...) |
| `cache` | `GemStack.cache` (memory / null / Redis stores) |
| `schema` | `GemStack::Types`, `GemStack::Schema`, `GemStack::Serializer` |
| `http` | routes, controllers (`accepts`, `input`, `render`), params, middleware, JSON |
| `db` *(require "gemstack/db")* | `GemStack::Model`, migrations, `GemStack.db`, `GemStack.transaction` |
| `jobs`, `mail`, `storage` *(require "gemstack/…")* | `GemStack::Job`, `GemStack::Mailer`, `GemStack::Storage` |
| `contract` | `gemstack contract`: TypeScript types, clients, OpenAPI |
| `dev` | `gemstack dev` (gateway + supervisor) |
| `cli` | the `gemstack` command and generators (the executable itself is the gemstack-cli gem) |

Authentication and realtime are the gems `gemstack-auth` and `gemstack-realtime`.

Core has no dependencies and never depends on the other gems. Modules plug
into core by registering configuration namespaces and boot hooks
(`GemStack::Plugins`). An automated test enforces these boundaries.

## A request

```text
Puma → RequestId → RequestLogger → Compression → ErrorHandler → [Reloader in dev]
     → SecurityHeaders → Cors → BodyLimit → HealthCheck → ETags → Router → YourController#action → JSON
```

Everything is plain Rack: `GemStack.application` is a Rack app, and any Rack
middleware can be added to the stack.

## Boot

`config.ru` → `config/app.rb` (`Bundler.require`, `GemStack.configure`) →
`GemStack.boot!`: load `.env` (dev/test), `config/environments/<env>.rb`,
plugin hooks, Zeitwerk for `app/*`, `config/routes.rb`, compile middleware,
eager-load in production.
