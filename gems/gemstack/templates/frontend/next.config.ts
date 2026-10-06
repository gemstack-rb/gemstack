import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type { NextConfig } from "next";

// One .env for the whole app: the root one, which the Ruby API reads too. Loaded
// here so `next build` and `next start` see it wherever they run — NEXT_PUBLIC_*
// values are compiled into the JavaScript at build time. Same files and order as
// GemStack (.env.<env>.local, .env.local, .env.<env>, .env; earlier files win)
// and the real environment always wins. Under `gemstack dev` it's already loaded.
function loadRootEnv(root = resolve(__dirname, "..")) {
  const env = process.env.GEMSTACK_ENV ?? (process.env.NODE_ENV === "production" ? "production" : "development");
  for (const file of [`.env.${env}.local`, ".env.local", `.env.${env}`, ".env"]) {
    let source: string;
    try {
      source = readFileSync(resolve(root, file), "utf8");
    } catch {
      continue;
    }
    for (const line of source.split(/\r?\n/)) {
      const match = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*)$/.exec(line);
      if (!match || line.trimStart().startsWith("#") || process.env[match[1]] !== undefined) continue;
      process.env[match[1]] = parseValue(match[2].trim());
    }
  }
}

function parseValue(value: string): string {
  if (value.startsWith('"')) {
    const body = /^"((?:[^"\\]|\\.)*)"/.exec(value)?.[1] ?? value.slice(1);
    const escapes: Record<string, string> = { n: "\n", t: "\t", r: "\r" };
    return body.replace(/\\(.)/g, (_, char: string) => escapes[char] ?? char);
  }
  if (value.startsWith("'")) return /^'([^']*)'/.exec(value)?.[1] ?? value.slice(1);
  return value.replace(/\s+#.*$/, "");
}

loadRootEnv();

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
