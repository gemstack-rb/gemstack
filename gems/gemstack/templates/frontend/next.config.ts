import type { NextConfig } from "next";

// One public origin, in every environment:
// - `gemstack dev`: the GemStack gateway routes /api/* to Ruby before requests reach Next.js.
// - Production with Kamal (gemstack generate deploy): kamal-proxy routes /api/* to Ruby.
// - Elsewhere: set GEMSTACK_API_URL (e.g. http://api.internal:4000) at build time and
//   Next.js proxies /api/* to the Ruby API.
const apiUrl = process.env.GEMSTACK_API_URL?.replace(/\/$/, "");
const apiPath = process.env.NEXT_PUBLIC_GEMSTACK_API_PATH ?? "/api";

const nextConfig: NextConfig = {
  // The production image (gemstack generate deploy) runs Next.js's standalone server.
  output: process.env.GEMSTACK_NEXT_OUTPUT === "standalone" ? "standalone" : undefined,
  async rewrites() {
    if (!apiUrl) return [];
    return [{ source: `${apiPath}/:path*`, destination: `${apiUrl}${apiPath}/:path*` }];
  },
};

export default nextConfig;
