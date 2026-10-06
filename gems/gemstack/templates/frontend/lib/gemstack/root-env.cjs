// One .env for the whole app: the root one, which the Ruby API reads too.
// Loads it into process.env when required — by next.config.ts (next dev,
// next build, next start) and, for Next.js's standalone server, which doesn't
// run next.config.ts, as a preload:
//
//   node -r ./lib/gemstack/root-env.cjs .next/standalone/server.js
//
// Same files and order as GemStack: .env.<env>.local, .env.local, .env.<env>,
// .env (earlier files win); the real environment always wins. <env> is
// GEMSTACK_ENV, else NODE_ENV, else production (a bare `node server.js`).
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const ESCAPES = { n: "\n", t: "\t", r: "\r" };

function parseValue(value) {
  if (value.startsWith('"')) {
    const body = /^"((?:[^"\\]|\\.)*)"/.exec(value)?.[1] ?? value.slice(1);
    return body.replace(/\\(.)/g, (_, char) => ESCAPES[char] ?? char);
  }
  if (value.startsWith("'")) return /^'([^']*)'/.exec(value)?.[1] ?? value.slice(1);
  return value.replace(/\s+#.*$/, "");
}

function loadRootEnv(root = resolve(__dirname, "../../..")) {
  const env = process.env.GEMSTACK_ENV || process.env.NODE_ENV || "production";
  for (const file of [`.env.${env}.local`, ".env.local", `.env.${env}`, ".env"]) {
    let source;
    try {
      source = readFileSync(resolve(root, file), "utf8");
    } catch {
      continue;
    }
    for (const line of source.split(/\r?\n/)) {
      const match = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*)$/.exec(line);
      if (!match || process.env[match[1]] !== undefined) continue;
      process.env[match[1]] = parseValue(match[2].trim());
    }
  }
}

loadRootEnv();

module.exports = { loadRootEnv };
