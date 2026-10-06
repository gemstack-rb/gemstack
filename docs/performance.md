# Performance

GemStack's rule: make the default path cheap by construction, then
**measure** before optimising anything else. Every default below is backed by
a measurement (the scripts are in `benchmarks/`).

## Defaults

| | Default | Why |
|---|---|---|
| JIT | YJIT in production (`config.jit`) | +27% end-to-end throughput (D-039) |
| Server | Puma threads (`GEMSTACK_MAX_THREADS`), workers + `preload_app!` via `WEB_CONCURRENCY` | |
| Routing | static paths: one hash lookup; dynamic: segment trie | cost depends on path depth, not route count |
| Middleware | compiled once at boot, 9 small middlewares | ≈4 µs for the default stack; ETags +2 µs |
| JSON | stdlib `JSON::Coder` (json 3) | faster than Oj on real payloads (D-037) |
| Serialization | compiled per serializer | 3× faster than the first version (D-038) |
| Compression | Brotli 4 (with the `brotli` gem) / gzip 4, ≥ 1 KB | best CPU/size balance measured (D-033) |
| HTTP caching | automatic weak ETags + 304s; `stale?` skips rendering | |
| Pagination | generated `index` actions paginate (25 per page, max 100) | no unbounded responses (D-034) |
| Database | Sequel pool = Puma threads, lazy connect, slow-query WARN | |
| App cache | `GemStack.cache` (memory; Redis optional) | |

## Measurements

Apple Silicon laptop, Ruby 4.0.7, json 3.0.2. Scripts in `benchmarks/`
(`bundle exec rake bench`; `benchmarks/server_bench.sh` for end to end).
Laptop numbers are noisy; treat them as relative.

### End to end (Puma, 5 threads, 1 process, `ab -k -c 10`, median of 5)

20 serialized records through the full default stack:

| Mode | req/s |
|---|---:|
| interpreter | 17,600 |
| **YJIT** | **22,300** (+27%) |
| ZJIT | 18,800 (+7%) |

### In-process (YJIT)

| Benchmark | µs/op | allocations |
|---|---:|---:|
| router: static path (602 routes) | 0.27 | 4 |
| router: dynamic path | 1.85 | 22 |
| request: health check (middleware only) | 5.9 | 39 |
| request: `show`, full default stack | 12.0 | 80 |
| request: index of 20, no compression, no ETags | 11.1 | 52 |
| … + ETags | 14.1 | 58 |
| … + gzip response | 31.4 | 90 |
| … + Brotli response | 29.0 | 83 |
| serializer: 20 records | 18.8 | 83 |
| JSON encode 20 records: stdlib / Oj | 2.8 / 3.4 | 1 / 2 |

### Serialization (the biggest per-request cost)

| 20 records | before (D-038) | after |
|---|---:|---:|
| interpreter | 90 µs, 163 allocs | 30 µs, 83 allocs |
| YJIT | 52 µs | 18 µs |

### Compression, varied 26 KB JSON body (YJIT)

| Encoder | Output | Time |
|---|---:|---:|
| gzip 1 | 33.2% | 123 µs |
| **gzip 4 (default)** | 29.1% | 246 µs |
| gzip 6 | 27.2% | 481 µs |
| Brotli 1 | 31.8% | 82 µs |
| **Brotli 4 (default)** | 28.9% | 210 µs |
| Brotli 5 | 26.5% | 401 µs |
| Brotli 11 | ~similar | ~15,000 µs — never for dynamic responses |

Highly repetitive JSON (the same keys and similar values) compresses to 4–7%
at any level, so higher gzip levels buy almost nothing there either.

## Compression

On by default; no configuration needed. Brotli needs `gem "brotli"` (new apps
include it); otherwise gzip is used. If a CDN or reverse proxy already compresses, keep
GemStack's (it skips already-encoded responses) or turn one off:

```ruby
config.http.compression.enabled = false
config.http.compression.min_size = 2048
config.http.compression.encodings = %w[gzip]
config.http.compression.gzip_level = 6
```

A response opts out with `headers["cache-control"] = "no-transform"`.

**BREACH.** Compressing a response that contains a secret (e.g. a CSRF
token) *and* reflects attacker-controlled input can leak the secret. JSON APIs
using bearer tokens in headers are generally unaffected. If you return such
bodies, mark those responses `no-transform`.

## HTTP caching

Every buffered 200 response gets a weak ETag, and a matching `If-None-Match`
gets a `304` with no body. Responses without `Cache-Control` get
`max-age=0, private, must-revalidate`. To skip the work entirely:

```ruby
def show
  product = Product.find(params[:id])
  render product if stale?(etag: product, last_modified: product.updated_at)
end

cache_control max_age: 60, public: true            # for data that may be cached
```

## Profiling your app

- `config.db.slow_query_ms` (default 500) logs slow SQL at WARN in every environment.
- Each request log line has `ms` (from first middleware until the body closes).
- The benchmark scripts are small; copy one and point it at your own controller.
