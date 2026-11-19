// Haltewekker shared ride logs (0.28.1): Settings › Help improve Haltewekker › Share ride logs (off unless turned on).
//
// A phone that shares sends the matching and ride lines of its field log, already scrubbed on the phone (no
// coordinates, no place names of yours, no names or account ids), grouped by a random install id that is not the
// Friends account. Kept 60 days in one Durable Object with SQLite storage (declared in wrangler.jsonc). Nothing here
// logs a line, an install id or a secret.
//
// Routes:
//   POST /logs/v1/put     {"install": 32 hex, "secret": 64 hex, "app": "0.28.1 (117)", "lines": ["…", …]}
//                         the body may be gzipped (sniffed by its first bytes). The first put of an install keeps a hash
//                         of its secret; later puts and the delete must bring the same secret.
//                         -> {"ok":true,"id":n,"lines":n}
//   POST /logs/v1/delete  {"install", "secret"}                     -> {"ok":true,"deleted":n}  (everything of that install)
//   GET  /logs/v1/export?since=<unix seconds | ISO date>&after=<id>&limit=<n>&format=json|text
//                         needs "Authorization: Bearer <LOGS_ADMIN_KEY>" (a Worker secret set in the dashboard);
//                         without that secret set: 503 "not configured"; a wrong or missing key: 401.
//                         -> {"uploads":[{"id","install","app","at","lines":[…]}],"next":id,"more":bool}
//                            (format=text: one line per log line, "<at ISO> <install 8> <app> <line>")

const KEEP = 60 * 86400;                  // seconds an upload is kept
const MAX_BODY = 256 * 1024;              // one request as sent (gzipped or not)
const MAX_PLAIN = 320 * 1024;             // one request unzipped (the app sends at most 200 KB of lines)
const MAX_LINES = 4000;                   // lines per put
const MAX_LINE = 2000;                    // characters per line (longer ones are cut)
const DAY_BYTES = 3 * 1024 * 1024;        // per install per day (the app stops at 2 MB)
const DAY_PUTS = 60;                      // per install per day
const IP_PUTS_PER_HOUR = 120;             // per network address (hashed)
const TOTAL_BYTES = 800 * 1024 * 1024;    // all uploads together: full beyond this
const EXPORT_BYTES = 4 * 1024 * 1024;     // one export answer, about
const HEX32 = /^[0-9a-f]{32}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const APP = /^[0-9A-Za-z .()_-]{1,40}$/;

const enc = new TextEncoder();
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const sha256hex = async (s) => hex(await crypto.subtle.digest("SHA-256", enc.encode(s)));
const json = (o, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
const fail = (error, status) => json({ error }, status);

/// Anything that still looks like a coordinate (a number with 5 or more decimals, or a pair of numbers with 3 or more)
/// goes, whatever the phone sent: a second guard behind the phone's own scrubbing.
export function scrubLine(s) {
  let t = String(s).slice(0, MAX_LINE).replace(/[\u0000-\u001f\u007f]/g, " ");
  t = t.replace(/-?\d{1,3}[.,]\d{3,}\s*[,;/ ]\s*-?\d{1,3}[.,]\d{3,}/g, "[coord]");
  t = t.replace(/-?\d{1,3}\.\d{5,}/g, "[coord]");
  return t;
}

/// Reads at most `max` bytes of a body, gunzipping it when it starts with the gzip magic bytes. Null: too big or broken.
export async function readBody(buf, max = MAX_PLAIN) {
  const u = new Uint8Array(buf);
  if (u.length < 2 || u[0] !== 0x1f || u[1] !== 0x8b) return u.length <= max ? u : null;
  try {
    const stream = new Blob([u]).stream().pipeThrough(new DecompressionStream("gzip"));
    const reader = stream.getReader();
    const parts = [];
    let n = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      n += value.length;
      if (n > max) { await reader.cancel().catch(() => {}); return null; }
      parts.push(value);
    }
    const out = new Uint8Array(n);
    let i = 0;
    for (const p of parts) { out.set(p, i); i += p.length; }
    return out;
  } catch { return null; }
}

/// Same length strings compared in time that doesn't depend on where they differ.
function sameText(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/// The Worker's part: the shape of a request, the admin key, then the one Durable Object that keeps the uploads.
export async function logs(request, env, url) {
  const path = url.pathname;
  if (path === "/logs/v1/export") {
    if (request.method !== "GET") return fail("method", 405);
    const key = env.LOGS_ADMIN_KEY || env["LOGS-ADMIN-KEY"];
    if (!key) return new Response("not configured", { status: 503, headers: { "Cache-Control": "no-store" } });
    const auth = request.headers.get("Authorization") || "";
    const given = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
    // (compared as hashes, so neither the length nor the place of a difference shows)
    if (!given || !sameText(await sha256hex("hw-logs:" + given), await sha256hex("hw-logs:" + key))) return fail("unauthorized", 401);
    if (!env.LOGS) return fail("no_storage", 503);
    return store(env).fetch("https://do/export" + url.search, { method: "GET" });
  }
  if (path !== "/logs/v1/put" && path !== "/logs/v1/delete") return fail("not_found", 404);
  if (request.method !== "POST") return fail("method", 405);
  if (!env.LOGS) return fail("no_storage", 503);
  const len = Number(request.headers.get("Content-Length") || "0");
  if (len > MAX_BODY) return fail("too_big", 413);
  const raw = await request.arrayBuffer();
  if (raw.byteLength > MAX_BODY) return fail("too_big", 413);
  const body = await readBody(raw);
  if (!body) return fail("too_big", 413);
  let input;
  try { input = JSON.parse(new TextDecoder().decode(body)); } catch { return fail("bad_json", 400); }
  if (typeof input !== "object" || input === null || Array.isArray(input)) return fail("bad_json", 400);
  const install = typeof input.install === "string" ? input.install.toLowerCase() : "";
  const secret = typeof input.secret === "string" ? input.secret.toLowerCase() : "";
  if (!HEX32.test(install)) return fail("bad_install", 400);
  if (!HEX64.test(secret)) return fail("bad_secret", 400);
  const out = { install, hash: await sha256hex("hw-logs-secret-v1:" + secret) };
  if (path === "/logs/v1/put") {
    const app = typeof input.app === "string" ? input.app : "";
    if (!APP.test(app)) return fail("bad_app", 400);
    const lines = input.lines;
    if (!Array.isArray(lines) || lines.length === 0 || lines.length > MAX_LINES || !lines.every((l) => typeof l === "string"))
      return fail("bad_lines", 400);
    const ip = request.headers.get("CF-Connecting-IP") || "unknown";
    out.ip = (await sha256hex("hw-logs-ip-v1:" + ip)).slice(0, 32);
    out.app = app;
    out.lines = lines.map(scrubLine);
  }
  return store(env).fetch("https://do" + (path === "/logs/v1/put" ? "/put" : "/delete"), { method: "POST", body: JSON.stringify(out) });
}

const store = (env) => env.LOGS.get(env.LOGS.idFromName("all"));

/// All uploads, in one object: SQLite tables of uploads, installs (with their secret's hash) and rate counts.
export class LogsCore {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.sql = ctx.storage.sql;
    this.schema();
  }

  schema() {
    this.sql.exec(`CREATE TABLE IF NOT EXISTS uploads (id INTEGER PRIMARY KEY AUTOINCREMENT, install TEXT NOT NULL,
      app TEXT NOT NULL, at INTEGER NOT NULL, size INTEGER NOT NULL, n INTEGER NOT NULL, body TEXT NOT NULL)`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS uploads_at ON uploads (at)`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS uploads_install ON uploads (install)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS installs (install TEXT PRIMARY KEY, hash TEXT NOT NULL, first INTEGER NOT NULL,
      last INTEGER NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS rate (bucket TEXT PRIMARY KEY, n INTEGER NOT NULL, exp INTEGER NOT NULL)`);
  }

  now() { return Math.floor(Date.now() / 1000); }

  /// Adds `by` to a bucket; false (and nothing added) once that would pass the limit.
  bump(bucket, limit, life, by = 1) {
    const now = this.now();
    const r = this.sql.exec(`SELECT n FROM rate WHERE bucket = ? AND exp >= ?`, bucket, now).toArray();
    const n = (r.length ? r[0].n : 0) + by;
    if (n > limit) return false;
    this.sql.exec(`INSERT INTO rate (bucket, n, exp) VALUES (?, ?, ?) ON CONFLICT(bucket) DO UPDATE SET n = excluded.n, exp = excluded.exp`,
      bucket, n, now + life);
    return true;
  }

  async fetch(request) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/put") return await this.put(await request.json());
      if (url.pathname === "/delete") return this.remove(await request.json());
      if (url.pathname === "/export") return this.exportAll(url.searchParams);
      return fail("not_found", 404);
    } catch (e) {
      return fail("relay_error", 500);
    }
  }

  prune() {
    const now = this.now();
    this.sql.exec(`DELETE FROM uploads WHERE at < ?`, now - KEEP);
    this.sql.exec(`DELETE FROM installs WHERE last < ?`, now - KEEP);
    this.sql.exec(`DELETE FROM rate WHERE exp < ?`, now);
  }

  async put({ install, hash, ip, app, lines }) {
    const now = this.now();
    this.prune();
    const known = this.sql.exec(`SELECT hash FROM installs WHERE install = ?`, install).toArray();
    if (known.length && !sameText(known[0].hash, hash)) return fail("wrong_secret", 403);
    const body = lines.join("\n");
    const size = enc.encode(body).length;
    const total = this.sql.exec(`SELECT COALESCE(SUM(size), 0) AS s FROM uploads`).toArray()[0].s;
    if (total + size > TOTAL_BYTES) return fail("full", 507);
    const day = Math.floor(now / 86400);
    if (!this.bump(`ip:${ip}:${Math.floor(now / 3600)}`, IP_PUTS_PER_HOUR, 3700)) return fail("slow_down", 429);
    if (!this.bump(`puts:${install}:${day}`, DAY_PUTS, 90000)) return fail("slow_down", 429);
    if (!this.bump(`bytes:${install}:${day}`, DAY_BYTES, 90000, size)) return fail("slow_down", 429);
    if (known.length) this.sql.exec(`UPDATE installs SET last = ? WHERE install = ?`, now, install);
    else this.sql.exec(`INSERT INTO installs (install, hash, first, last) VALUES (?, ?, ?, ?)`, install, hash, now, now);
    this.sql.exec(`INSERT INTO uploads (install, app, at, size, n, body) VALUES (?, ?, ?, ?, ?, ?)`, install, app, now, size, lines.length, body);
    const id = this.sql.exec(`SELECT last_insert_rowid() AS id`).toArray()[0].id;
    await this.wake(now + 86400);
    return json({ ok: true, id, lines: lines.length });
  }

  remove({ install, hash }) {
    const known = this.sql.exec(`SELECT hash FROM installs WHERE install = ?`, install).toArray();
    if (!known.length) return json({ ok: true, deleted: 0 });
    if (!sameText(known[0].hash, hash)) return fail("wrong_secret", 403);
    const deleted = this.sql.exec(`DELETE FROM uploads WHERE install = ?`, install).rowsWritten || 0;
    this.sql.exec(`DELETE FROM installs WHERE install = ?`, install);
    return json({ ok: true, deleted });
  }

  exportAll(q) {
    this.prune();
    const s = q.get("since") || "0";
    let since = /^\d{1,11}$/.test(s) ? Number(s) : Math.floor(Date.parse(s) / 1000);
    if (!Number.isFinite(since)) return fail("bad_since", 400);
    const after = /^\d{1,15}$/.test(q.get("after") || "") ? Number(q.get("after")) : 0;
    const limit = /^\d{1,5}$/.test(q.get("limit") || "") ? Math.min(Math.max(Number(q.get("limit")), 1), 5000) : 1000;
    const rows = this.sql.exec(`SELECT id, install, app, at, size, body FROM uploads WHERE at >= ? AND id > ? ORDER BY id LIMIT ?`,
      since, after, limit + 1).toArray();
    const out = [];
    let bytes = 0;
    for (const r of rows.slice(0, limit)) {
      if (out.length && bytes + r.size > EXPORT_BYTES) break;
      bytes += r.size;
      out.push({ id: r.id, install: r.install, app: r.app, at: r.at, lines: r.body.split("\n") });
    }
    const next = out.length ? out[out.length - 1].id : after;
    const more = rows.length > out.length;
    if (q.get("format") === "text") {
      const text = out.flatMap((u) => {
        const when = new Date(u.at * 1000).toISOString().slice(0, 19) + "Z";
        return u.lines.map((l) => `${when} ${u.install.slice(0, 8)} ${u.app} ${l}`);
      }).join("\n");
      return new Response(text + (text ? "\n" : ""), {
        headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store", "X-Next": String(next), "X-More": String(more) },
      });
    }
    return json({ uploads: out, next, more });
  }

  async wake(at) {
    const cur = await this.ctx.storage.getAlarm();
    if (cur === null || cur > at * 1000) await this.ctx.storage.setAlarm(at * 1000);
  }

  /// Once a day while anything is kept: what's older than 60 days goes.
  async alarm() {
    this.prune();
    const left = this.sql.exec(`SELECT COUNT(*) AS n FROM uploads`).toArray()[0].n;
    if (left > 0) await this.ctx.storage.setAlarm((this.now() + 86400) * 1000);
  }
}
