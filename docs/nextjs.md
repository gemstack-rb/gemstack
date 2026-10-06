# Next.js

The frontend in `frontend/` is a standard Next.js App Router project in
TypeScript. You can install any npm package and use any Next.js feature;
GemStack adds only three things:

| File | Purpose |
|---|---|
| `lib/gemstack/client.ts` | the API client runtime (yours to edit) |
| `app/providers.tsx` | TanStack Query provider with sensible retry defaults |
| `next.config.ts` | `/api/*` rewrites for gateway-less production (HTTP, and the realtime WebSocket or stream) |

## One origin

In development the gateway on `localhost:3000` sends `/api/*` to Ruby and
everything else — pages, assets, the `/_next/hmr` WebSocket — to Next.js. The
realtime WebSocket is `/api/realtime`, so it goes to Ruby like any API call.
Browser code calls **relative** URLs, so there is no CORS, no API base URL and
no proxy configuration.

## Generated clients and hooks

For resources, use the generated, typed client (see [TypeScript](typescript.md))
and the hooks `generate resource` writes to `lib/queries/`:

```tsx
import { useProducts, useCreateProduct } from "@/lib/queries/products";

const products = useProducts(page);             // useQuery → Paginated<Product> ({ data, meta })
const create = useCreateProduct();              // useMutation, invalidates the list
await create.mutateAsync({ name: "Lamp", price: "9.99" });
```

## Calling the API directly

```ts
import { api, ApiError } from "@/lib/gemstack/client";

const products = await api.get<Product[]>("/products", { query: { page: 2 } });
const created  = await api.post<Product>("/products", { product: { name: "Lamp" } });
await api.patch(`/products/${id}`, { product: { name: "Desk lamp" } });
await api.delete(`/products/${id}`);

try {
  await api.post("/products", {});
} catch (error) {
  if (error instanceof ApiError) {
    error.status;     // 400
    error.code;       // "parameter_missing"
    error.errors;     // { product: ["is required"] }
    error.requestId;  // matches the Ruby log line
  }
}
```

Paths are relative to the API path (`/api`). JSON bodies are encoded
automatically; `FormData`, `Blob` and `URLSearchParams` are sent as-is.

### In Server Components

The same client works on the server. There, relative URLs don't exist, so it
uses `GEMSTACK_API_URL` — which `gemstack dev` sets to the internal Ruby
address — and calls Ruby directly:

```tsx
// app/products/page.tsx (a Server Component)
export default async function Products() {
  const products = await api.get<Product[]>("/products", { cache: "no-store" });
  return <ProductTable products={products} />;
}
```

In production, set `GEMSTACK_API_URL` for the Next.js process.

## State management

- **Server state:** TanStack Query (`useQuery`, `useMutation`). 4xx responses
  are not retried; transient failures are retried twice.
- **Local UI state:** `useState` / `useReducer`.
- **URL state:** Next.js `searchParams` / `useSearchParams`.

No Redux and no GemStack store. Add Zustand, Jotai or anything else if your
app needs it.

## Environment variables

| Variable | Where | Meaning |
|---|---|---|
| `GEMSTACK_API_URL` | Next.js server | internal Ruby URL (set by `gemstack dev`; set it in production) |
| `NEXT_PUBLIC_GEMSTACK_API_PATH` | build/browser | API path if not `/api` (set by `gemstack dev` from `config.http.api_path`) |
| `NEXT_PUBLIC_GEMSTACK_API_URL` | build/browser | only for an API on another domain (then configure CORS) |
