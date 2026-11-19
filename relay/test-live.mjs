// A check of the live links (live.js): locally with the Durable Objects faked, or against the live relay.
// Run: node relay/test-live.mjs
// Or:  node relay/test-live.mjs https://haltewekker-relay.tsfaw1.workers.dev   (one throwaway link, ended at the end)
// Both make a link, lock a state with its key as the app does (AES-256-GCM, see live.js), fetch the page and its script,
// run that script on a tiny stand-in for a browser so it decrypts the state with the key from the link's #, and check
// what it shows; then the limits, ending the link, and that the NS routes still answer (live only).
import assert from "node:assert/strict";
import vm from "node:vm";
import { live, LiveCore, liveToken } from "./live.js";

const LIVE = process.argv[2] || null;
const b64u = (b) => Buffer.from(b).toString("base64url");

// MARK: fakes (local)

class FakeStorage {
  constructor() { this.map = new Map(); this.alarmAt = null; }
  async get(k) { const v = this.map.get(k); return v === undefined ? undefined : structuredClone(v); }
  async put(k, v) { this.map.set(k, structuredClone(v)); }
  async delete(k) { return this.map.delete(k); }
  async deleteAll() { this.map.clear(); }
  async getAlarm() { return this.alarmAt; }
  async setAlarm(t) { this.alarmAt = t; }
  async deleteAlarm() { this.alarmAt = null; }
}
class FakeNamespace {
  constructor() { this.objects = new Map(); }
  idFromName(n) { return n; }
  get(id) {
    const ns = this;
    return {
      async fetch(url, init) {
        if (!ns.objects.has(id)) ns.objects.set(id, new LiveCore({ storage: new FakeStorage() }, {}));
        return ns.objects.get(id).fetch(url instanceof Request ? url : new Request(url, init));
      },
    };
  }
}

const base = LIVE || "https://relay.test";
let call;
if (LIVE) {
  call = (path, init) => fetch(LIVE + path, init);
} else {
  const env = { LIVE: new FakeNamespace() };
  call = (path, init) => live(new Request(base + path, init), env, new URL(base + path));
}

// MARK: the app's side

async function lock(state, keyBytes, token, nonce = crypto.getRandomValues(new Uint8Array(12))) {
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "AES-GCM" }, false, ["encrypt"]);
  const aad = new TextEncoder().encode("hw-live-v1\n" + token);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: aad, tagLength: 128 }, key,
    new TextEncoder().encode(JSON.stringify(state))));
  return new Uint8Array([1, ...nonce, ...ct]);
}
async function put(secret, data, until) {
  const r = await call("/live/v1/put", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret: b64u(secret), data: b64u(data), until }) });
  return { status: r.status, json: await r.json().catch(() => null) };
}
async function end(secret) {
  const r = await call("/live/v1/end", { method: "POST", body: JSON.stringify({ secret: b64u(secret) }) });
  return { status: r.status, json: await r.json().catch(() => null) };
}
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const two = (n) => (n < 10 ? "0" : "") + n;
const hhmm = (t) => { const d = new Date(t * 1000); return two(d.getHours()) + ":" + two(d.getMinutes()); };

// MARK: the page, on a stand-in for a browser

async function runPage(link, script) {
  const u = new URL(link);
  const els = {};
  const el = (id) => (els[id] ??= { id, textContent: "", hidden: true, className: "", style: {}, clientWidth: 320, clientHeight: 220,
    children: [], appendChild(c) { this.children.push(c); } });
  const timers = [];
  const ctx = {
    location: { pathname: u.pathname, hash: u.hash },
    document: {
      title: "", visibilityState: "visible",
      getElementById: el,
      createElement: () => ({ style: {} }),
      addEventListener() {},
    },
    fetch: (path, init) => call(path.startsWith("/") ? path : new URL(path).pathname + new URL(path).search, init),
    crypto: globalThis.crypto, TextEncoder, TextDecoder, atob, Date, Math, JSON, Error, Promise, String, Number, Uint8Array,
    encodeURIComponent,
    setTimeout: (f, ms) => { timers.push(ms); return timers.length; }, clearTimeout() {},
  };
  ctx.window = ctx;
  vm.createContext(ctx);
  vm.runInContext(script, ctx);
  for (let i = 0; i < 100 && (els.head?.textContent ?? "").startsWith("Opening"); i++) await pause(50);
  await pause(100);
  return { els, ctx, timers };
}

// MARK: the checks

const secret = crypto.getRandomValues(new Uint8Array(32));
const keyBytes = crypto.getRandomValues(new Uint8Array(32));
const token = await liveToken(secret);
assert.match(token, /^[A-Za-z0-9_-]{22}$/);
const link = `${base}/live/${token}#${b64u(keyBytes)}`;
const now = Math.floor(Date.now() / 1000);
const state = { v: 1, name: "Sam", state: "riding", mode: "bus", line: "305", from: "Veghel, Busstation", to: "Den Bosch",
  dest: "Breda", eta: now + 1200, end: now + 3600, late: 3, pos: { lat: 51.6167, lon: 5.5486, at: now - 10 }, t: now };

// nothing there yet
let r = await call(`/live/v1/get?t=${token}`);
assert.equal(r.status, 404);
assert.equal((await call("/live/v1/get?t=short")).status, 400);
// a bad secret, bad data, a bad until
assert.equal((await put(new Uint8Array(16), await lock(state, keyBytes, token), now + 600)).status, 400);
assert.equal((await put(secret, new Uint8Array([2, 1, 2, 3]), now + 600)).status, 400);
assert.equal((await put(secret, await lock(state, keyBytes, token), now + 5)).status, 400);
// made
let p = await put(secret, await lock(state, keyBytes, token), now + 6 * 3600);
assert.equal(p.status, 200, JSON.stringify(p.json));
assert.equal(p.json.token, token);
assert.ok(p.json.exp <= now + 4 * 3600 + 5, "at most 4 hours");
// too soon again
assert.equal((await put(secret, await lock(state, keyBytes, token), now + 3600)).status, 429);

// the page and its script
r = await call(`/live/${token}`);
assert.equal(r.status, 200);
assert.match(r.headers.get("Content-Type") || "", /text\/html/);
assert.match(r.headers.get("Content-Security-Policy") || "", /script-src 'self'/);
assert.equal(r.headers.get("Referrer-Policy"), "strict-origin");
assert.equal(r.headers.get("Cache-Control"), "no-store");
const html = await r.text();
assert.ok(html.includes('<script src="/live/app.js"></script>'));
assert.ok(!/<script>/.test(html), "no inline script");
assert.ok(!html.includes(token), "the page doesn't carry the token");
r = await call("/live/app.js");
assert.equal(r.status, 200);
const script = await r.text();

// the relay's answer: locked bytes only
r = await call(`/live/v1/get?t=${token}`);
assert.equal(r.status, 200);
const got = await r.json();
assert.ok(!JSON.stringify(got).includes("Sam"));
// decrypted here with the key from the link, as the page does
const box = Buffer.from(got.data, "base64url");
const k = await crypto.subtle.importKey("raw", Buffer.from(new URL(link).hash.slice(1), "base64url"), { name: "AES-GCM" }, false, ["decrypt"]);
const plain = JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: box.subarray(1, 13),
  additionalData: new TextEncoder().encode("hw-live-v1\n" + token) }, k, box.subarray(13))));
assert.deepEqual(plain, state);
// and by the page's own script
let page = await runPage(link, script);
assert.equal(page.els.head.textContent, `Sam is on bus 305 to Den Bosch · arrives ${hhmm(state.eta)} · 3 min late`);
assert.equal(page.els.detail.textContent, `Then on to Breda · there around ${hhmm(state.end)}`);
assert.equal(page.els.map.hidden, false);
assert.ok(page.els.tiles.children.length >= 2 && page.els.tiles.children[0].src.startsWith("https://tile.openstreetmap.org/15/"));
assert.ok(page.timers.includes(15000), "polls again in 15 s");
// a wrong key
page = await runPage(`${base}/live/${token}#${b64u(crypto.getRandomValues(new Uint8Array(32)))}`, script);
assert.match(page.els.head.textContent, /key doesn’t fit/);
// no key
page = await runPage(`${base}/live/${token}`, script);
assert.match(page.els.head.textContent, /missing its key/);

// arrived (the app's last state), then ended
await pause(5200);
const arrived = { ...state, state: "arrived", eta: now + 60, pos: undefined, late: undefined, t: now + 60 };
p = await put(secret, await lock(arrived, keyBytes, token), now + 900);
assert.equal(p.status, 200, JSON.stringify(p.json));
page = await runPage(link, script);
assert.equal(page.els.head.textContent, `Sam has arrived at Den Bosch · ${hhmm(arrived.eta)}`);
assert.equal(page.els.badge.textContent, "Arrived");
assert.equal(page.els.map.hidden, true);
const e = await end(secret);
assert.equal(e.status, 200);
assert.equal((await end(secret)).status, 200, "ending twice is fine");
r = await call(`/live/v1/get?t=${token}`);
assert.equal(r.status, 410);
page = await runPage(link, script);
assert.equal(page.els.head.textContent, "This link has ended");
await pause(5200);
assert.equal((await put(secret, await lock(state, keyBytes, token), now + 900)).status, 410, "an ended link stays ended");
assert.equal((await call("/live/v1/nothing")).status, 404);

if (LIVE) {
  const ns = await fetch(LIVE + "/ns/departures?station=BD");
  assert.equal(ns.status, 200, "NS departures still answer");
  const st = await fetch(LIVE + "/f/v1/status");
  assert.equal(st.status, 200);
  console.log("live relay: NS departures", ns.status, "· friends status", st.status);
}
console.log("live links: all checks passed", LIVE ? "(live)" : "(local)");
