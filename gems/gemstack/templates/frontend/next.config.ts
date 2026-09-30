import type { NextConfig } from "next";

// One public origin, in every environment:
// - `gemstack dev`: the GemStack gateway routes /api/* to Ruby before requests reach Next.js.
// - Production: set GEMSTACK_API_URL (e.g. http://api.internal:4000) and Next.js proxies
//   /api/* to the Ruby API. Leave it unset if a reverse proxy already routes /api/*.
const apiUrl = process.env.GEMSTACK_API_URL?.replace(/\/$/, "");
const apiPath = process.env.NEXT_PUBLIC_GEMSTACK_API_PATH ?? "/api";

const nextConfig: NextConfig = {
  async rewrites() {
    if (!apiUrl) return [];
    return [{ source: `${apiPath}/:path*`, destination: `${apiUrl}${apiPath}/:path*` }];
  },
};

export default nextConfig;
