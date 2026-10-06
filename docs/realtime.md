# Realtime

Notifications, live updates, chat, presence and subscriptions between the
Ruby API and browsers, over **WebSockets** or **Server-Sent Events** — same
features, same application code. Realtime is optional: an app that doesn't add
it pays nothing.

```bash
gemstack add realtime      # gem, config/channels.rb, frontend/lib/gemstack/realtime.ts, test helpers
```

Application code uses three things — `GemStack.broadcast` on the server,
`config/channels.rb` for what browsers may do, and `frontend/lib/gemstack/realtime.ts`
in the browser — and never touches a socket.

## Broadcasting (server → browsers)

From anywhere — controllers, jobs, the console:

```ruby
GemStack.broadcast("orders:#{order.id}", "order.updated", order)   # serialized with OrderSerializer
GemStack.broadcast("announcements", "maintenance", { at: "22:00" })
GemStack.broadcast("users:#{user.id}", "notification", notification) # one user: a channel per user
```

Data is serialized like `render` (serializers by convention), so browsers get
the API's shapes and the TypeScript types match. On PostgreSQL a broadcast
made inside a transaction is delivered **only when it commits**.

## Channels (config/channels.rb, deny by default)

```ruby
GemStack.channels do
  # Who is connecting: once per connection (and per POSTed message), from its cookies/headers.
  # nil = anonymous. A Hash with :id is also the presence metadata.
  identify { |request| GemStack::Auth.user_from(request)&.then { |u| { id: u.id, name: u.name } } }

  channel "announcements"                                   # anyone may subscribe
  channel "orders:*" do |order_id, request|                 # * = one segment, passed to the block
    Order.find_by(id: order_id)&.user_id == identity(request)&.fetch(:id)
  end
  channel "rooms:*", presence: true do |room_id, request|   # + who's here
    Membership.exists?(room_id: room_id, user_id: identity(request)&.fetch(:id))
  end

  # Browser → server: realtime.send("rooms:1", "say", { body }) — only to
  # channels the connection is subscribed to. The return value is the reply;
  # raising GemStack::BadRequest (etc.) replies with that error.
  receive "rooms:*" do |message|
    post = Post.create!(room_id: message.params.first, body: message.data["body"], user_id: message.identity[:id])
    GemStack.broadcast(message.channel, "post.created", post)
    { id: post.id }
  end
end
```

- A channel that matches no `channel` rule can't be subscribed to; the first
  matching rule decides. Blocks get the connection's `Rack::Request`, and
  `identity(request)` is what `identify` returned.
- `message` has `channel`, `event`, `data`, `params` (the `*` segments),
  `identity` and `request`.
- `GemStack::Auth.user_from(request)` (with `gemstack add auth`) is the signed-in
  user from the session cookie or a Bearer API token. Same-origin connections
  carry the session cookie automatically.
- Authorization blocks and `receive` handlers run on a small thread pool
  (`config.realtime.workers`), one message at a time per connection, under the
  same lock as requests (code reloading waits for them). The file reloads in
  development.

## Browser

```tsx
import { realtime, usePresence, useRealtime, useRealtimeStatus, GAP_EVENT } from "@/lib/gemstack/realtime";

// Subscribed while the component is mounted.
useRealtime<Order>(`orders:${id}`, (event) => {
  if (event.event === "order.updated") queryClient.setQueryData(["orders", id], event.data);
  if (event.event === GAP_EVENT) queryClient.invalidateQueries({ queryKey: ["orders", id] });
});

// Send to a subscribed channel; resolves with the `receive` handler's return value.
const reply = await realtime.send<{ id: number }>("rooms:1", "say", { body: "Hi" }); // RealtimeError on refusal

const people = usePresence<{ name: string }>("rooms:1"); // [{ id, meta: { name } }]
const status = useRealtimeStatus();                      // idle | connecting | open | reconnecting | offline
realtime.transport;                                      // "websocket" | "sse" while open

// Outside components:
const off = realtime.subscribe("announcements", (event) => showBanner(event.data));
off();
```

Events are `{ id, channel, event, data }`. The client:

- opens **one connection per tab** when the first channel is subscribed and
  closes it after the last one goes;
- **reconnects** with exponential backoff (0.5 s → 30 s, with jitter) and
  **resubscribes** with the last event id — the server **replays** what was
  missed (`replay_size` / `replay_ttl`), or the channel's handlers get
  **`gemstack.gap`** to refetch;
- is **`offline`** while the browser is (its `offline`/`online` events), and
  reconnects as soon as it's back;
- gives a refused channel's handlers **`gemstack.denied`**;
- replaces a connection that stays silent for three heartbeats;
- drops duplicate events (a replay can overlap live delivery).

Presence rides out short drops: a connection that comes back within
`config.realtime.presence_grace` (3 s) — a reconnect, a page navigation, an
SSE stream reopened for new channels — is no leave and join for the others.

## Transports

| | WebSocket | Server-Sent Events |
|---|---|---|
| Server → browser | frames on the socket | `GET <api_path>/realtime?channels=a,b` (an `EventSource`) |
| Browser → server (`realtime.send`) | frames on the socket | `POST <api_path>/realtime` (JSON) |
| Changing subscriptions | a message | the stream is reopened (batched; presence unaffected) |
| Through proxies | needs upgrades passed (kamal-proxy, the dev gateway and `next start` rewrites do) | anything that passes HTTP streaming |

Both register with the same hub, so a WebSocket client and an SSE client on one
channel see each other's broadcasts and presence. Choose in the browser with
`NEXT_PUBLIC_GEMSTACK_REALTIME` (set at `next build`, like any `NEXT_PUBLIC_`
variable):

- `auto` (default) — WebSocket; if one can't be opened (refused, or no welcome
  within 5 s), Server-Sent Events for the rest of the page's life. A WebSocket
  that worked and then dropped just reconnects.
- `websocket` or `sse` — only that one.

On the server, `config.realtime.transports` (default `[:websocket, :sse]`) lists
what the endpoint accepts. Without `:websocket`, upgrades get 404 (and `auto`
clients fall back); without `:sse`, stream and POST requests get 426.

Treat events as signals and let TanStack Query refetch authoritative data, or
apply small payloads directly.

## Protocol

### WebSocket

`GET <api_path>/realtime` with `Upgrade: websocket`, then JSON text messages:

| Direction | `type` | Fields |
|---|---|---|
| → server | `subscribe` / `unsubscribe` | `channel`, `last_id?`, `ref?` |
| → server | `message` | `channel`, `event`, `data?`, `ref?` |
| → server | `ping` | |
| ← browser | `welcome` | `connection_id`, `heartbeat` |
| ← browser | `subscribed` / `unsubscribed` | `channel`, `ref?`, `presence?` (list) |
| ← browser | `denied` | `channel`, `ref?`, `code` (`forbidden`, `invalid_channel`, `too_many_channels`) |
| ← browser | `event` | `id`, `channel`, `event`, `data` |
| ← browser | `gap` | `channel` |
| ← browser | `presence` | `channel`, `event` (`join`/`leave`), `id`, `meta?` |
| ← browser | `reply` | `ref`, `ok`, `data?` or `error: { code, message }` |
| ← browser | `error` / `pong` | `code`, `message` |

### Server-Sent Events

`GET <api_path>/realtime?channels=a,b[&last_event_id=…]` (or the
`Last-Event-ID` header) streams `data:` lines, each a JSON
`{ id, channel, event, data }`. Application events have an `id`; the
transport's own events don't:

| `event` | `channel` | `data` |
|---|---|---|
| `gemstack.welcome` | | `{ connection_id, transport: "sse", heartbeat }` |
| `gemstack.ping` | | every `heartbeat` seconds |
| `gemstack.presence` | a presence channel | the list `[{ id, meta? }]`, on open |
| `presence.join` / `presence.leave` | a presence channel | `{ id, meta? }` / `{ id }` |
| `gemstack.denied` | the refused channel | `"forbidden"` (the other channels keep working) |
| `gemstack.gap` | | events were missed and can't be replayed |

`POST <api_path>/realtime` with `Content-Type: application/json` and
`{ "channel", "event", "data" }` runs the channel's `receive` handler (if the
sender may subscribe to the channel) and answers `200 { "data": <reply> }`, or
the usual error envelope (`403 forbidden`, `404 no_handler`, `400`, `413`…).

Other clients (mobile apps, services) can speak either protocol directly; send
`Authorization: Bearer <api token>` and `identify` can use
`GemStack::Auth.user_from(request)`.

## How it works

```text
GemStack.broadcast ──▶ broker ──▶ every API process ──▶ Hub ──▶ WebSocket and SSE connections
                     (NOTIFY)     (listener thread)      (channel → connections, replay buffer)
```

- **Same origin.** The connection goes to the API's own path. In development
  the GemStack gateway relays it like any `/api` request; in production
  kamal-proxy (or your reverse proxy) routes `/api` — WebSocket upgrades
  included — to Puma. See [one origin](#one-origin).
- **No request threads held.** The handshake or stream request runs as a
  normal request (Origin check, `identify`, channel rules), then Puma hands the
  socket over (Rack full hijack) to one `nio4r` event loop per process, which
  reads frames, writes without blocking, sends a heartbeat every 15 s, drops
  clients that stop answering (three heartbeats) or fall more than 1 MB behind. Application code runs on the worker pool, never
  on the loop. Measured on a laptop: 500 open WebSockets on a 2-thread Puma,
  one broadcast reaches all of them in ~5 ms, and the API keeps answering
  normally (20 requests in 6 ms).
- **Security.** The `Origin` must be the API's own origin (or one of
  `config.http.cors.origins`, or `config.realtime.allowed_origins`), which stops
  cross-site WebSocket hijacking; POSTs must be JSON, so a cross-site form can't
  send one. Messages are limited in size (64 KB) and, on a WebSocket, rate
  (20/s per connection); channels per connection are limited (50).
- **Presence** is shared between processes through the broker: each process
  announces joins and leaves and refreshes them every 15 s; an entry from a
  process that stops refreshing lapses after three intervals. A second tab of
  the same identity is not a new join. `GemStack::Realtime.present_on("rooms:1")`
  reads it on the server.
- **Replaceable pieces.** RFC 6455 framing is `GemStack::Realtime::WebSocket::Codec`
  (no extensions; no dependency beyond `nio4r`); the broker is
  `config.realtime.broker` — any object with `#publish(message)` and `#start { |message| }`.

| Broker | When | Notes |
|---|---|---|
| `:postgres` | default when the database is PostgreSQL | LISTEN/NOTIFY, transactional, payloads ≤ ~8 KB |
| `:redis` | default when `REDIS_URL` is set (and the database isn't PostgreSQL); large payloads / high rates | `gem "redis-client"` |
| `:memory` | otherwise: one process only | jobs workers can't reach browsers — use PostgreSQL or Redis |
| `:test` | in tests | records broadcasts |

## One origin

```text
browser ──▶ :3000 GemStack gateway (dev) / kamal-proxy (production)
              ├── /api/*  (HTTP and the /api/realtime WebSocket) ──▶ Puma, internal port
              └── everything else ──────────────────────────────────▶ Next.js, internal port
```

Next.js `rewrites` (deployments without a proxy in front, `GEMSTACK_API_URL`
set at build) carry both transports: `next start` passes WebSocket upgrades on
rewrites to the API (verified with Next.js 16 in `script/e2e`), and the stream
is plain HTTP. If anything in front drops upgrades, `auto` clients use
Server-Sent Events. nginx needs `proxy_http_version 1.1` and the
`Upgrade`/`Connection` headers for `/api/realtime`.

With the API on another domain (`NEXT_PUBLIC_GEMSTACK_API_URL`), list the site
in `config.http.cors.origins` with `config.http.cors.credentials = true`: the
WebSocket and the stream send cookies, and the stream answers with its own CORS
headers.

## Testing

`gemstack add realtime` includes the helpers in `GemStack::TestCase`:

```ruby
def test_updating_an_order_notifies_viewers
  patch_json "/api/orders/#{order.id}", { status: "shipped" }

  assert_broadcast "orders:#{order.id}", "order.updated"
  assert_broadcast "orders:#{order.id}", "order.updated", data: OrderSerializer.serialize(order.reload)
  refute_broadcast "orders:999"
end
```

Test rules with `GemStack.channels.authorized?(name, request)`, and `receive`
handlers by calling `GemStack.channels.receiver(name)`.

## Configuration

| Setting | Default |
|---|---|
| `config.realtime.broker` | `:postgres` with a PostgreSQL database, `:redis` with `REDIS_URL`, else `:memory`; `:test` in tests |
| `config.realtime.path` | `"#{api_path}/realtime"` |
| `config.realtime.transports` | `[:websocket, :sse]` |
| `config.realtime.heartbeat` | `15` s (WebSocket pings, SSE `gemstack.ping`; silent for three → disconnected) |
| `config.realtime.replay_size` / `replay_ttl` | `1000` events / `300` s |
| `config.realtime.max_channels` | `50` per connection |
| `config.realtime.max_message_size` | `65536` bytes per browser message |
| `config.realtime.max_messages_per_second` | `20` per connection |
| `config.realtime.workers` | `4` threads for authorization and `receive` |
| `config.realtime.allowed_origins` | `nil` (same origin + `config.http.cors.origins`) |
| `config.realtime.presence_interval` | `15` s |
| `config.realtime.presence_grace` | `3` s a dropped connection stays present |
| `config.realtime.max_buffer` | 1 MB before a slow client is dropped |
| `config.realtime.redis_url` / `redis_channel` | `REDIS_URL` / `gemstack:realtime:<app>` |
| `config.realtime.retry_ms` | `3000` (the SSE `retry:` hint) |
| `NEXT_PUBLIC_GEMSTACK_REALTIME` (frontend) | `auto` (`websocket`, `sse`) |

## Upgrading from the earlier client

Apps that added realtime with GemStack 0.3.x have an `EventSource`-only
`frontend/lib/gemstack/realtime.ts`. It keeps working (Server-Sent Events are a
supported transport). For WebSocket, `realtime.send`, presence and the
`offline` status, replace the file with the new client — copy it from a fresh
`gemstack add realtime` — and keep using `useRealtime`/`realtime.subscribe` as
before; `onStatus`, `GAP_EVENT` and `DENIED_EVENT` are unchanged.
