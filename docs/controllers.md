# Controllers

```ruby
class ProductsController < ApplicationController
  before :load_product, only: %i[show update]
  rescue_from Payments::Declined, status: 402, code: "payment_declined"

  def index
    render Products::Catalog.page(params.fetch(:page, 1).to_i)
  end

  def show = render(@product)

  def create
    attrs = params.require(:product).permit(:name, :price, tags: [], dimensions: %i[width height])
    render Products::Catalog.create(attrs), status: :created
  end

  def update
    @product.update(params.require(:product).permit(:name))
    head :no_content
  end

  private

  def load_product
    @product = Products::Catalog.find(params[:id]) or raise GemStack::NotFound, "Product not found"
  end
end
```

Actions are the **public** methods you define. Private methods are never
routable.

## Responses

| | |
|---|---|
| `render value` | JSON, status 200 |
| `render value, status: :created` | symbolic or numeric status |
| `render value, headers: { "cache-control" => "max-age=60" }` | |
| `head :no_content` | empty body |
| `headers["x-total-count"] = "42"` | add headers any time |
| *(nothing)* | an action that doesn't render responds `204 No Content` |

Rendering twice raises `DoubleRenderError`.

`render product` uses `ProductSerializer` by convention (also for arrays and
datasets); `render x, serializer: OtherSerializer` overrides it — see
[serialization](serialization.md). Plain hashes, arrays, strings, numbers,
booleans and nil are encoded natively; `Time` → ISO 8601, `Date`, `Symbol`,
`Set`, `BigDecimal` (as a string) are converted; other objects must define
`#as_json` or `#to_h`. **Anything else raises** instead of leaking `#inspect`
output. Override `serialize(value)` for custom behaviour.

## Input

Declare what an action accepts; read it with `input` (see [validation](validation.md)):

```ruby
accepts :create, with: Product.input_schema
accepts :update, with: Product.input_schema, partial: true
accepts(:search) { required :q, :string }
returns :search, [ProductSerializer]      # response type for the TypeScript client

def create = render(Product.create(input), status: :created)
```

## Params

`params` merges query string, body (JSON object or form) and path parameters —
path wins, then body, then query. Keys are accessible as strings or symbols.

```ruby
params[:id]                         # "42"
params.require(:product)            # 400 parameter_missing if absent or blank
params.permit(:name, :price)        # => { name: "Lamp", price: "9.99" } (symbol keys)
params.permit(tags: [])             # arrays of scalars
params.permit(dimensions: %i[w h])  # nested objects (or arrays of objects)
params.to_h                         # unfiltered copy — prefer permit for persisted input
request.json                        # the raw parsed JSON body (any JSON value)
```

`permit` only returns scalars and structures you declare, so unexpected nested
data never reaches your models. Malformed JSON → `400 invalid_json`; nesting
deeper than 64 levels is rejected.

## Callbacks

```ruby
before :authenticate                      # method name
before(only: :destroy) { head :forbidden unless admin? }   # block
after { headers["x-served-by"] = "gemstack" }
skip_before :authenticate                 # in a subclass
```

A `before` callback that renders halts the request; the action doesn't run.
Callbacks and `rescue_from` handlers are inherited.

## Errors

Raise errors anywhere; they become the standard envelope:

```ruby
raise GemStack::NotFound                                  # 404 not_found
raise GemStack::Forbidden, "Only owners can do that"      # 403
raise GemStack::ValidationError.new(errors: { name: ["is required"] })   # 422
raise GemStack::Conflict.new("Already paid", code: "already_paid")
```

```json
{ "error": { "code": "validation_failed", "message": "Validation failed: name is required", "request_id": "…" },
  "errors": { "name": ["is required"] } }
```

Available: `BadRequest` 400, `Unauthorized` 401, `Forbidden` 403, `NotFound`
404, `MethodNotAllowed` 405, `Conflict` 409, `PayloadTooLarge` 413,
`UnsupportedMediaType` 415, `ValidationError` 422, `TooManyRequests` 429,
`ServiceUnavailable` 503. Any exception class with `#status` and `#code`
methods is rendered the same way — your own errors don't need to inherit from
GemStack's.

Unexpected exceptions are `500 internal_error`: logged with backtrace and
request ID; the response includes exception details only when
`config.http.show_exceptions` is on (development and test).

`rescue_from` maps errors per controller:

```ruby
rescue_from Stripe::CardError, with: :card_declined              # method (receives the error)
rescue_from(Timeout::Error) { |e| render({ retry: true }, status: 503) }
rescue_from Faraday::TimeoutError, status: 504                   # envelope with code "gateway_timeout"
```

## Request

`request` is a `Rack::Request` with extras: `request.request_id`,
`request.path_params`, `request.route`, `request.json`, `request.json?`.

## Pagination

```ruby
returns :index, GemStack::Page[ProductSerializer]      # TypeScript: list(query?: PaginationQuery): Promise<Paginated<Product>>

def index
  render paginate(Product.where(active: true).order(:name))           # ?page=2&per_page=50
end
```

```json
{ "data": [ … ], "meta": { "page": 2, "per_page": 25, "total": 180, "total_pages": 8 } }
```

`per_page` defaults to `config.http.pagination.per_page` (25) and is capped at
`max_per_page` (100); `paginate(scope, per_page: 10)` changes the default for
one action. Invalid values are a 422. Order the dataset so pages are stable.
Arrays work too. Everything about pagination — settings, the frontend hooks,
large tables: [pagination](pagination.md).

Custom actions appear in `openapi.json`, the TypeScript client and
`/api/docs` like generated ones; declare `accepts` and `returns` so their
input and response are typed — see [documenting custom
endpoints](typescript.md#documenting-custom-endpoints).

## HTTP caching

```ruby
def show
  product = Product.find(params[:id])
  render product if stale?(etag: product, last_modified: product.updated_at)   # 304 skips rendering
end

cache_control max_age: 300, public: true, stale_while_revalidate: 30
cache_control :no_store
```

Without these, buffered 200 responses still get an automatic weak ETag and
304 handling (`config.http.etags`).

