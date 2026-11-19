// A check of the shared ride logs (logs.js) without Cloudflare: the Durable Object faked with node:sqlite.
// Run: node relay/test-logs.mjs            (Node 22.13+)
// Or against the live relay (puts and then deletes one throwaway install; export must refuse without the key):
//      node relay/test-logs.mjs https://haltewekker-relay.tsfaw1.workers.dev
import { DatabaseSync } from "node:sqlite";
import assert from "node:assert/strict";
import { gzipSync } from "node:zlib";
import { logs, LogsCore, scrubLine, readBody, cleanFix } from "./logs.js";

const LIVE = process.argv[2] || null;

class FakeStorage {
  constructor() { this.db = new DatabaseSync(":memory:"); this.alarmAt = null; this.sql = this.makeSql(); }
  makeSql() {
    const db = () => this.db;
    return {
      exec(q, ...binds) {
        const st = db().prepare(q);
        if (/^\s*SELECT/i.test(q)) { const rows = st.all(...binds); return { toArray: () => rows, rowsWritten: 0 }; }
        const r = st.run(...binds);
        return { toArray: () => [], rowsWritten: Number(r.changes) };
      },
    };
  }
  async getAlarm() { return this.alarmAt; }
  async setAlarm(t) { this.alarmAt = t; }
}

class FakeNamespace {
  constructor() { this.objects = new Map(); }
  idFromName(n) { return n; }
  get(id) {
    const ns = this;
    return {
      async fetch(url, init) {
        if (!ns.objects.has(id)) ns.objects.set(id, new LogsCore({ storage: new FakeStorage() }, {}));
        return ns.objects.get(id).fetch(url instanceof Request ? url : new Request(url, init));
      },
    };
  }
}

const hex = (n) => Buffer.from(crypto.getRandomValues(new Uint8Array(n))).toString("hex");

function client(base, env) {
  return async (path, { method = "POST", body, gzip = false, headers = {} } = {}) => {
    let data = body === undefined ? undefined : Buffer.from(typeof body === "string" ? body : JSON.stringify(body));
    if (data && gzip) data = gzipSync(data);
    const init = { method, headers: { "Content-Type": "application/json", ...headers }, body: data };
    const r = base ? await fetch(base + path, init) : await logs(new Request("https://relay" + path, init), env, new URL("https://relay" + path));
    const text = await r.text();
    let json = null;
    try { json = JSON.parse(text); } catch {}
    return { status: r.status, json, text };
  };
}

async function local() {
  // the second guard: coordinates go, everything else stays
  assert.equal(scrubLine("start · its stop 16630 m from you · leg 1/3"), "start · its stop 16630 m from you · leg 1/3");
  assert.equal(scrubLine("at 51.61612, 5.53125 now"), "at [coord] now");
  assert.equal(scrubLine("at 51.616123 now"), "at [coord] now");
  assert.equal(scrubLine("1.2 KB · 0.4 s"), "1.2 KB · 0.4 s");
  assert.equal((await readBody(gzipSync(Buffer.from("hello")))).length, 5);
  assert.equal(await readBody(gzipSync(Buffer.alloc(1100 * 1024))), null);       // a zip bomb stops at the limit

  const env = { LOGS: new FakeNamespace() };
  const call = client(null, env);
  const install = hex(16), secret = hex(32);
  const lines = ["2026-11-19 07:33:58 ride start · Home on board, by itself · bus 305·7821 · its stop 16630 m from you · leg 1/3"];

  let r = await call("/logs/v1/put", { body: { install, secret, app: "0.28.1 (117)", lines }, gzip: true });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.lines, 1);
  r = await call("/logs/v1/put", { body: { install, secret, app: "0.28.1 (117)", lines: ["x 52.123456"] } });
  assert.equal(r.status, 200, r.text);
  // another secret for the same install: refused
  r = await call("/logs/v1/put", { body: { install, secret: hex(32), app: "0.28.1 (117)", lines } });
  assert.equal(r.status, 403);
  r = await call("/logs/v1/delete", { body: { install, secret: hex(32) } });
  assert.equal(r.status, 403);
  // bad shapes
  assert.equal((await call("/logs/v1/put", { body: { install: "x", secret, app: "a", lines } })).status, 400);
  assert.equal((await call("/logs/v1/put", { body: { install, secret, app: "a", lines: [] } })).status, 400);
  assert.equal((await call("/logs/v1/put", { body: { install, secret, app: "a", lines: [3] } })).status, 400);
  assert.equal((await call("/logs/v1/put", { body: "not json" })).status, 400);
  assert.equal((await call("/logs/v1/put", { method: "GET" })).status, 405);
  assert.equal((await call("/logs/v1/put", { body: { install, secret, app: "a", lines: ["y".repeat(600 * 1024)] } })).status, 413);

  // GPS points (0.32): checked, rounded again, kept with their upload
  const fix = { t: 1763534038.25, lat: 51.4412345, lon: 5.4781234, acc: 8.4, spd: 12.34, crs: 87.6, leg: "1/3", veh: "bus 305·7821", ride: "a1b2c3d4" };
  assert.deepEqual(cleanFix(fix), { t: 1763534038.3, lat: 51.44123, lon: 5.47812, acc: 8, spd: 12.3, crs: 88, leg: "1/3", veh: "bus 305·7821", ride: "a1b2c3d4" });
  assert.deepEqual(cleanFix({ t: 1763534038, lat: 51.1, lon: 5.1, spd: -1, crs: -1, extra: "dropped" }), { t: 1763534038, lat: 51.1, lon: 5.1, spd: -1, crs: -1 });
  assert.equal(cleanFix({ t: 1763534038, lat: 91, lon: 5 }), null);
  assert.equal(cleanFix({ t: 12, lat: 51, lon: 5 }), null);
  assert.equal(cleanFix({ t: 1763534038, lat: 51, lon: 5, veh: "<script>" }), null);
  assert.equal(cleanFix({ t: 1763534038, lat: 51, lon: 5, leg: "first" }), null);
  assert.equal(cleanFix([1, 2]), null);
  const fixes = [fix, { ...fix, t: fix.t + 3, lat: 51.44133 }];
  r = await call("/logs/v1/put", { body: { install, secret, app: "0.32.0 (123)", lines: ["2026-11-19 07:34:01 ride gps"], fixes, tz: 3600 }, gzip: true });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.fixes, 2);
  // only points (ride logs off): no lines
  r = await call("/logs/v1/put", { body: { install, secret, app: "0.32.0 (123)", lines: [], fixes: [fix] } });
  assert.equal(r.status, 200, r.text);
  assert.equal((await call("/logs/v1/put", { body: { install, secret, app: "a", lines: [], fixes: [] } })).status, 400);
  assert.equal((await call("/logs/v1/put", { body: { install, secret, app: "a", lines, fixes: [{ t: 1 }] } })).status, 400);
  assert.equal((await call("/logs/v1/put", { body: { install, secret, app: "a", lines, fixes: "no" } })).status, 400);
  assert.equal((await call("/logs/v1/put", { body: { install, secret, app: "a", lines, fixes: [fix], tz: 99999999 } })).status, 400);
  assert.equal((await call("/logs/v1/put", { body: { install, secret, app: "a", lines, fixes: Array(8001).fill({ t: fix.t, lat: 51.1, lon: 5.1 }) }, gzip: true })).status, 400);
  // a day's worth of points in one gzipped put fits (the app sends at most 600 KB of them at a time)
  const many = Array.from({ length: 5000 }, (_, i) => ({ ...fix, t: fix.t + 3 * i, lat: 51.44123 + i * 1e-5 }));
  r = await call("/logs/v1/put", { body: { install, secret, app: "0.32.0 (123)", lines: [], fixes: many, tz: 3600 }, gzip: true });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.fixes, 5000);

  // export: not configured, then a wrong key, then the right one
  r = await call("/logs/v1/export", { method: "GET" });
  assert.equal(r.status, 503);
  assert.equal(r.text, "not configured");
  env.LOGS_ADMIN_KEY = "k".repeat(40);
  assert.equal((await call("/logs/v1/export", { method: "GET" })).status, 401);
  assert.equal((await call("/logs/v1/export", { method: "GET", headers: { Authorization: "Bearer nope" } })).status, 401);
  r = await call("/logs/v1/export?since=0", { method: "GET", headers: { Authorization: "Bearer " + env.LOGS_ADMIN_KEY } });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.uploads.length, 5);
  assert.deepEqual(r.json.uploads[0].lines, lines);
  assert.deepEqual(r.json.uploads[1].lines, ["x [coord]"]);
  assert.equal(r.json.uploads[0].install, install);
  assert.equal(r.json.uploads[0].fixes, undefined, "no points: no fixes");
  assert.equal(r.json.uploads[2].fixes.length, 2);
  assert.equal(r.json.uploads[2].fixes[0].lat, 51.44123);
  assert.equal(r.json.uploads[2].fixes[1].veh, "bus 305·7821");
  assert.equal(r.json.uploads[2].tz, 3600);
  assert.deepEqual(r.json.uploads[3].lines, []);
  assert.equal(r.json.uploads[3].tz, undefined);
  assert.equal(r.json.uploads[4].fixes.length, 5000);
  r = await call("/logs/v1/export?since=0&limit=1", { method: "GET", headers: { Authorization: "Bearer " + env.LOGS_ADMIN_KEY } });
  assert.equal(r.json.uploads.length, 1);
  assert.equal(r.json.more, true);
  r = await call(`/logs/v1/export?since=0&after=${r.json.next}&limit=1`, { method: "GET", headers: { Authorization: "Bearer " + env.LOGS_ADMIN_KEY } });
  assert.equal(r.json.uploads.length, 1);
  assert.equal(r.json.more, true);
  r = await call(`/logs/v1/export?since=0&after=${r.json.next}`, { method: "GET", headers: { Authorization: "Bearer " + env.LOGS_ADMIN_KEY } });
  assert.equal(r.json.uploads.length, 3);
  assert.equal(r.json.more, false);
  r = await call("/logs/v1/export?since=2026-01-01&format=text", { method: "GET", headers: { Authorization: "Bearer " + env.LOGS_ADMIN_KEY } });
  assert.equal(r.status, 200);
  assert.match(r.text, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ [0-9a-f]{8} 0\.28\.1 \(117\) 2026-11-19 07:33:58 ride start/);
  assert.ok(!r.text.includes("51.44"), "the text export leaves the points out");
  assert.equal(r.text.trim().split("\n").length, 3);
  r = await call("/logs/v1/export?since=soon", { method: "GET", headers: { Authorization: "Bearer " + env.LOGS_ADMIN_KEY } });
  assert.equal(r.status, 400);

  // the delete: everything of that install goes
  r = await call("/logs/v1/delete", { body: { install, secret } });
  assert.equal(r.status, 200);
  assert.equal(r.json.deleted, 5);
  r = await call("/logs/v1/export?since=0", { method: "GET", headers: { Authorization: "Bearer " + env.LOGS_ADMIN_KEY } });
  assert.equal(r.json.uploads.length, 0);
  const left = env.LOGS.objects.get("all").sql.exec(`SELECT COUNT(*) AS n FROM fixes`).toArray()[0].n;
  assert.equal(left, 0, "the points went with the delete");
  // gone: a new secret may start that id again
  assert.equal((await call("/logs/v1/put", { body: { install, secret: hex(32), app: "a", lines } })).status, 200);

  // a day's puts are capped per install
  const other = hex(16), s2 = hex(32);
  let last = 200;
  for (let i = 0; i < 61; i++) last = (await call("/logs/v1/put", { body: { install: other, secret: s2, app: "a", lines: ["l"] } })).status;
  assert.equal(last, 429);
  console.log("logs relay: all local checks passed");
}

async function live(base) {
  const call = client(base);
  const install = hex(16), secret = hex(32);
  // made-up points in the North Sea, so nothing real is ever sent by the check
  const fixes = [0, 3, 6].map((s) => ({ t: Math.floor(Date.now() / 1000) - 60 + s, lat: 53.0 + s * 1e-4, lon: 3.0, acc: 10, spd: 12, crs: 0,
    leg: "1/1", veh: "bus 0·0000", ride: "00000000" }));
  let r = await call("/logs/v1/put", {
    body: { install, secret, app: "0.32.0 (check)", lines: ["2026-11-19 00:00:00 ride relay check · throwaway"], fixes, tz: 3600 }, gzip: true,
  });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.fixes, 3, r.text);
  console.log("put:", r.status, JSON.stringify(r.json));
  // with the admin key in LOGS_ADMIN_KEY (never printed): the export has the points
  const key = process.env.LOGS_ADMIN_KEY;
  if (key) {
    const e = await call(`/logs/v1/export?since=${Math.floor(Date.now() / 1000) - 600}&after=${r.json.id - 1}&limit=5`, {
      method: "GET", headers: { Authorization: "Bearer " + key } });
    assert.equal(e.status, 200, `export with the key: ${e.status}`);
    const mine = e.json.uploads.find((u) => u.install === install);
    assert.ok(mine, "the check's upload is in the export");
    assert.equal(mine.fixes.length, 3);
    assert.equal(mine.tz, 3600);
    console.log("export with the key:", e.status, `${mine.lines.length} line, ${mine.fixes.length} fixes, tz ${mine.tz}`);
    const t = await call(`/logs/v1/export?since=${Math.floor(Date.now() / 1000) - 600}&after=${r.json.id - 1}&limit=5&format=text`, {
      method: "GET", headers: { Authorization: "Bearer " + key } });
    assert.equal(t.status, 200);
    assert.ok(t.text.includes("relay check") && !t.text.includes("53.000"), "text: lines, no points");
    console.log("text export with the key:", t.status);
  }
  r = await call("/logs/v1/delete", { body: { install, secret: hex(32) } });
  assert.equal(r.status, 403, r.text);
  r = await call("/logs/v1/delete", { body: { install, secret } });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.deleted, 1);
  console.log("delete:", r.status, JSON.stringify(r.json));
  r = await call("/logs/v1/export?since=0", { method: "GET" });
  assert.ok(r.status === 503 || r.status === 401, `export without the key: ${r.status}`);
  console.log("export without the key:", r.status, r.text.slice(0, 40));
  r = await call("/logs/v1/export?since=0", { method: "GET", headers: { Authorization: "Bearer " + hex(24) } });
  assert.ok(r.status === 503 || r.status === 401, `export with a wrong key: ${r.status}`);
  console.log("export with a wrong key:", r.status);
  const ns = await fetch(base + "/ns/departures?station=BD");
  console.log("ns departures BD:", ns.status);
  assert.equal(ns.status, 200);
  console.log("logs relay: live checks passed");
}

if (LIVE) await live(LIVE.replace(/\/$/, "")); else await local();
