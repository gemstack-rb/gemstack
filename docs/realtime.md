# Realtime

Push updates from the server to browsers: notifications, live lists,
dashboards, chat messages. Realtime is **optional**, so an app that doesn't
add it pays nothing.

```bash
gemstack add realtime      # gem, config/channels.rb, frontend/lib/gemstack/realtime.ts, test helpers
```

## Broadcasting

From anywhere — controllers, jobs, the console:

```ruby
GemStack.broadcast("orders:#{order.id}", "order.updated", order)   # serialized with OrderSerializer
GemStack.broadcast("announcements", "maintenance", { at: "22:00" })
```

Data is serialized exactly like `render` (serializers by convention), so
browsers get the same shapes as the API and the TypeScript types match.

On PostgreSQL the default broker is `LISTEN/NOTIFY`: a broadcast made inside a
transaction is delivered **only when it commits**, and a broadcast from a
background job reaches browsers connected to any API process. With SQLite or
MySQL, set `config.realtime.broker = :redis` (and `REDIS_URL`) when broadcasts
come from another process such as the jobs worker — the default memory broker
only reaches this process (`gemstack doctor` warns).

## Channels (deny by default)

```ruby
# config/channels.rb
GemStack.channels do
  channel "announcements"                          # anyone
  channel "orders:*" do |order_id, request|        # * = one segment, passed to the block
    Order.find_by(id: order_id)&.user_id == current_user_id(request)
  end
  channel "rooms:*:messages" do |room, request|
    Membership.exists?(room: room, user: current_user_id(request))
  end
end
```

A channel that matches no rule can't be subscribed to. The block receives the
Rack request (cookies, `Authorization` header) for your authentication, and
the file reloads in development.

## Subscribing (browser)

```tsx
import { useRealtime, realtime, GAP_EVENT, DENIED_EVENT } from "@/lib/gemstack/realtime";

// In a component: subscribed while mounted.
useRealtime<Order>(`orders:${id}`, (event) => {
  if (event.event === "order.updated") queryClient.setQueryData(["orders", id], event.data);
  if (event.event === GAP_EVENT) queryClient.invalidateQueries({ queryKey: ["orders", id] });
});

// Anywhere else:
const off = realtime.subscribe("announcements", (event) => showBanner(event.data));
off();
realtime.onStatus((status) => console.log(status)); // idle | connecting | open | reconnecting
```

Every event is `{ id, channel, event, data }`.

How the client behaves:

- **One connection per tab.** All channels share one `EventSource`;
  subscription changes made in the same tick cause a single reconnect.
- **Replay.** After a dropped connection the browser reconnects with
  `Last-Event-ID`, and the server replays what the tab missed (up to
  `replay_size` events / `replay_ttl` seconds).
- **`gemstack.gap`.** When replay isn't possible, every handler receives this
  event. Refetch, e.g. by invalidating TanStack Query caches.
- **`gemstack.denied`.** A refused channel's handlers receive this, and the
  tab's other channels keep working.

A good pattern is to treat realtime events as a signal and let TanStack Query
refetch the authoritative data (`invalidateQueries`). Push small payloads.

## How it works

```text
GemStack.broadcast ──▶ broker ──▶ every API process ──▶ Hub ──▶ SSE connections
                     (NOTIFY)     (LISTEN thread)       (channel → connections, replay buffer)
```

- **Transport: Server-Sent Events** on `GET /api/realtime?channels=a,b`. That's
  plain HTTP, so it works through the dev gateway, reverse proxies and
  Next.js rewrites, with automatic reconnects built into browsers. Messages
  from the browser to the server are ordinary API requests.
- **No request threads held.** The socket is taken over from Puma (Rack full
  hijack) and served by one `nio4r` event loop per process, which also sends
  heartbeats every 15 s and drops clients more than 1 MB behind. Thousands of
  open streams don't take Puma's threads (tested: 20 open streams on a
  2-thread server, and the API still answers).
- **Brokers:**

| Broker | When | Notes |
|---|---|---|
| `:postgres` | default when the database is PostgreSQL | LISTEN/NOTIFY, transactional, payloads ≤ ~8 KB |
| `:memory` | no database, single process | after-commit delivery when in a transaction |
| `:redis` | large payloads / high rates | `gem "redis-client"`, `REDIS_URL` |
| `:test` | in tests | records broadcasts |

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

Test channel rules directly with `GemStack.channels.authorized?(name, request)`.

## Deployment

- Works through **Next.js rewrites** (verified in production mode) and any
  reverse proxy. For nginx, GemStack sends `X-Accel-Buffering: no`; also set
  `proxy_read_timeout` above the 15 s heartbeat.
- Each API process holds one extra database connection for LISTEN (added to the
  pool automatically).
- Puma is required for connection hijacking. On other servers the endpoint
  falls back to streaming from a request thread (and logs a warning).

## Configuration

| Setting | Default |
|---|---|
| `config.realtime.broker` | `:postgres` when the database is PostgreSQL, `:redis` when `REDIS_URL` is set, else `:memory`; `:test` in tests |
| `config.realtime.path` | `"#{api_path}/realtime"` |
| `config.realtime.heartbeat` | `15` s |
| `config.realtime.replay_size` / `replay_ttl` | `1000` events / `300` s |
| `config.realtime.max_channels` | `50` per connection |
| `config.realtime.max_buffer` | 1 MB before a slow client is dropped |
| `config.realtime.retry_ms` | `3000` |
| `config.realtime.redis_url` / `redis_channel` | `REDIS_URL` / `gemstack:realtime:<app>` |

Not included (yet): presence (who's online), a WebSocket transport, typed
channel/event contracts in TypeScript.
