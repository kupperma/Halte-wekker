// A check of the live links (live.js, live-app.js): locally with the Durable Objects faked, or against the live relay.
// Run: node relay/test-live.mjs
// Or:  node relay/test-live.mjs https://haltewekker-relay.tsfaw1.workers.dev   (one throwaway link, ended at the end)
// Both make a link, lock a state with its key as the app does (AES-256-GCM, see live.js), fetch the page and its script,
// run that script on a tiny stand-in for a browser so it decrypts the state with the key from the link's #, and check
// what it shows (payload v1 from 0.30 apps, and v2 with the whole trip); messages from the page to the sharer and back;
// then the limits, ending the link, and that the NS routes still answer (live only). All names and places are made up.
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFileSync } from "node:fs";
import { live, LiveCore, liveToken } from "./live.js";

const LIVE = process.argv[2] || null;
const b64u = (b) => Buffer.from(b).toString("base64url");

// MARK: fakes (local)

class FakeStorage {
  constructor() { this.map = new Map(); this.alarmAt = null; }
  async get(k) { const v = this.map.get(k); return v === undefined ? undefined : structuredClone(v); }
  async put(k, v) { this.map.set(k, structuredClone(v)); }
  async delete(k) {
    if (Array.isArray(k)) { let n = 0; for (const x of k) if (this.map.delete(x)) n++; return n; }
    return this.map.delete(k);
  }
  async list({ prefix = "", start = "" } = {}) {
    const keys = [...this.map.keys()].filter((k) => k.startsWith(prefix) && k >= start).sort();
    return new Map(keys.map((k) => [k, structuredClone(this.map.get(k))]));
  }
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
let call, env = null;
if (LIVE) {
  call = (path, init) => fetch(LIVE + path, init);
} else {
  env = { LIVE: new FakeNamespace() };
  call = (path, init) => live(new Request(base + path, init), env, new URL(base + path));
}

// MARK: the app's side

async function seal(obj, keyBytes, aad, nonce = crypto.getRandomValues(new Uint8Array(12))) {
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "AES-GCM" }, false, ["encrypt"]);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: new TextEncoder().encode(aad), tagLength: 128 }, key,
    obj instanceof Uint8Array ? obj : typeof obj === "string" ? new TextEncoder().encode(obj) : new TextEncoder().encode(JSON.stringify(obj))));
  return new Uint8Array([1, ...nonce, ...ct]);
}
async function unseal(data, keyBytes, aad) {
  const box = Buffer.from(data, "base64url");
  const k = await crypto.subtle.importKey("raw", keyBytes, { name: "AES-GCM" }, false, ["decrypt"]);
  return new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: box.subarray(1, 13), additionalData: new TextEncoder().encode(aad) },
    k, box.subarray(13)));
}
const lock = (state, keyBytes, token, nonce) => seal(state, keyBytes, "hw-live-v1\n" + token, nonce);
const post = async (path, body, headers = {}) => {
  const r = await call(path, { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body) });
  return { status: r.status, json: await r.json().catch(() => null) };
};
const put = (secret, data, until) => post("/live/v1/put", { secret: b64u(secret), data: b64u(data), until });
const end = (secret) => post("/live/v1/end", { secret: b64u(secret) });
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const two = (n) => (n < 10 ? "0" : "") + n;
const hhmm = (t) => { const d = new Date(t * 1000); return two(d.getHours()) + ":" + two(d.getMinutes()); };

// MARK: the page, on a stand-in for a browser

let PAGE_HTML = "";
class El {
  constructor(tag, id = "", hidden = false) {
    this.tagName = tag; this.id = id; this.hidden = hidden; this.className = ""; this.children = []; this._text = ""; this.value = "";
    this.style = { setProperty() {} }; this.attrs = {}; this.on = {}; this.disabled = false;
  }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(""); }
  set textContent(v) { this._text = String(v); this.children = []; }
  get lastChild() { return this.children[this.children.length - 1]; }
  appendChild(c) { this.children.push(c); return c; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, f) { (this.on[t] ??= []).push(f); }
  click() { for (const f of this.on.click || []) f({}); }
  focus() {}
  setPointerCapture() {}
  getBoundingClientRect() { return { height: 400 }; }
}

async function runPage(link, script, storage = null, until = null) {
  const u = new URL(link);
  const history = { urls: [], replaceState(_s, _t, url) { this.urls.push(url); } };
  const els = {};
  // every element with an id, hidden as the page's HTML says
  for (const m of PAGE_HTML.matchAll(/<(\w+)[^>]*\sid="(\w+)"[^>]*>/g)) els[m[2]] = new El(m[1], m[2], /\shidden[\s>]/.test(m[0]));
  const timers = [];
  const ctx = {
    location: { pathname: u.pathname, hash: u.hash },
    document: {
      title: "", visibilityState: "visible", documentElement: new El("html"), body: new El("body"),
      getElementById: (id) => els[id] ?? (els[id] = new El("div", id)),
      createElement: (t) => new El(t),
      addEventListener() {},
    },
    fetch: (path, init) => call(path.startsWith("/") ? path : new URL(path).pathname + new URL(path).search, init),
    crypto: globalThis.crypto, TextEncoder, TextDecoder, atob, btoa, Date, Math, JSON, Error, Promise, String, Number, Uint8Array, Array, URL, isNaN, isFinite,
    encodeURIComponent, decodeURIComponent, history, innerWidth: 390, innerHeight: 844,
    setTimeout: (f, ms) => { timers.push(ms); return timers.length; }, clearTimeout() {}, setInterval: () => 1, clearInterval() {},
    requestAnimationFrame: () => 1, cancelAnimationFrame() {},
  };
  ctx.window = ctx;
  if (storage) ctx.localStorage = storage;
  vm.createContext(ctx);
  vm.runInContext(script, ctx);
  const done = until || (() => !(els.head.textContent ?? "").startsWith("Opening"));
  for (let i = 0; i < 100 && !done(els); i++) await pause(50);
  await pause(100);
  const timeline = () => els.tl.children.map((li) => ({ kind: li.className, time: li.children[0].textContent, title: li.children[2].children[0].textContent,
    sub: li.children[2].children[1]?.textContent ?? "" }));
  return { els, ctx, timers, history, timeline };
}
const newStorage = () => ({ m: new Map(), getItem(k) { return this.m.has(k) ? this.m.get(k) : null; }, setItem(k, v) { this.m.set(k, String(v)); },
  removeItem(k) { this.m.delete(k); } });

// MARK: the checks

const secret = crypto.getRandomValues(new Uint8Array(32));
const keyBytes = crypto.getRandomValues(new Uint8Array(32));
const token = await liveToken(secret);
assert.match(token, /^[A-Za-z0-9_-]{22}$/);
// (0.30.1) the app's links say "#k=<key>"; the page also takes 0.30's "#<key>"
const link = `${base}/live/${token}#k=${b64u(keyBytes)}`;
const now = Math.floor(Date.now() / 1000);
// a 0.30 app's state (v1)
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
assert.equal((await put(secret, new Uint8Array(16385).fill(1), now + 600)).status, 400, "at most 16 KB");
// made
let p = await put(secret, await lock(state, keyBytes, token), now + 6 * 3600);
assert.equal(p.status, 200, JSON.stringify(p.json));
assert.equal(p.json.token, token);
assert.equal(p.json.mseq, 0);
assert.ok(p.json.exp <= now + 4 * 3600 + 5, "at most 4 hours");
// too soon again
assert.equal((await put(secret, await lock(state, keyBytes, token), now + 3600)).status, 429);

// the page and its script
r = await call(`/live/${token}`);
assert.equal(r.status, 200);
assert.match(r.headers.get("Content-Type") || "", /text\/html/);
const csp = r.headers.get("Content-Security-Policy") || "";
assert.match(csp, /script-src 'self' https:\/\/unpkg\.com;/);
assert.match(csp, /connect-src 'self' https:\/\/tiles\.openfreemap\.org;/);
assert.doesNotMatch(csp, /unsafe-eval/);
assert.equal(r.headers.get("Referrer-Policy"), "strict-origin");
assert.equal(r.headers.get("Cache-Control"), "no-store");
const html = await r.text();
PAGE_HTML = html;
assert.ok(html.includes('<script src="/live/app.js" defer></script>'));
assert.match(html, /<script src="https:\/\/unpkg\.com\/maplibre-gl@\d+\.\d+\.\d+\/dist\/maplibre-gl\.js" integrity="sha384-[A-Za-z0-9+/=]{64}" crossorigin="anonymous" defer>/);
assert.ok(!/<script>/.test(html), "no inline script");
assert.ok(!html.includes(token), "the page doesn't carry the token");
assert.ok(!/Nana/.test(html), "no name in the page itself");
r = await call("/live/app.js");
assert.equal(r.status, 200);
const script = await r.text();
assert.ok(script.includes("hw-live-msg-v1"), "the new script");
assert.ok(!/Nana/.test(script), "no name in the script");

// the relay's answer: locked bytes only
r = await call(`/live/v1/get?t=${token}`);
assert.equal(r.status, 200);
const got = await r.json();
assert.ok(!JSON.stringify(got).includes("Sam"));
assert.equal(got.mseq, undefined, "no messages yet");
// decrypted here with the key from the link, as the page does
assert.deepEqual(JSON.parse(await unseal(got.data, Buffer.from(new URL(link).hash.slice(3), "base64url"), "hw-live-v1\n" + token)), state);

// v1 by the page's own script: the new look with what a 0.30 app sends
let page = await runPage(link, script);
assert.equal(page.els.eyebrow.textContent, "Live");
assert.equal(page.els.head.textContent, "Sam is on bus 305");
assert.equal(page.els.sub.textContent, "to Den Bosch · 3 min late");
assert.equal(page.els.face.textContent, "S");
assert.equal(page.els.big.hidden, false);
assert.equal(page.els.bigPlace.textContent, "Den Bosch");
assert.equal(page.els.bigTime.textContent, hhmm(state.eta));
assert.equal(page.els.bigSub.textContent, "in 20 min");
assert.equal(page.els.thenPlace.textContent, "Then Breda");
assert.equal(page.els.thenTime.textContent, hhmm(state.end));
assert.deepEqual(page.timeline().map((x) => [x.kind, x.title]),
  [["done", "Veghel, Busstation"], ["now", "On bus 305"], ["next", "Den Bosch"], ["next", "Breda"]]);
assert.match(page.timeline()[1].sub, /^3 min late · phone 1\d s$/);
assert.equal(page.timeline()[3].sub, `there around ${hhmm(state.end)}`);
assert.equal(page.els.msg.hidden, true, "a 0.30 app doesn't read messages: no box");
assert.equal(page.els.music.hidden, true);
assert.ok(page.timers.includes(15000), "polls again in 15 s");
assert.equal(page.ctx.document.title, "Sam is on bus 305 · Haltewekker");
// 0.30's form, a %-encoded one, one with something glued on after it, standard base64: the same key
const std = Buffer.from(keyBytes).toString("base64").replace(/=+$/, "");
for (const l of [`${base}/live/${token}#${b64u(keyBytes)}`, `${base}/live/${token}#k%3D${b64u(keyBytes)}`,
  `${base}/live/${token}#k=${b64u(keyBytes)}).`, `${base}/live/${token}#k=${encodeURIComponent(std)}`]) {
  await pause(600);
  page = await runPage(l, script);
  assert.equal(page.els.head.textContent, "Sam is on bus 305", l);
}
// a wrong key
page = await runPage(`${base}/live/${token}#${b64u(crypto.getRandomValues(new Uint8Array(32)))}`, script);
assert.match(page.els.head.textContent, /key doesn’t fit/);
// no key: said so, but not "Ended" while the trip is still shared
page = await runPage(`${base}/live/${token}`, script);
assert.match(page.els.head.textContent, /missing its key/);
assert.equal(page.els.eyebrow.textContent, "Key missing");
assert.match(page.els.sub.textContent, /Copy link/);
page = await runPage(`${base}/live/${token}#k=`, script);
assert.equal(page.els.eyebrow.textContent, "Key missing");
// a key that worked once in this browser: opened again without the #, it still works (and the link is whole again)
const storage = newStorage();
await pause(600);
page = await runPage(link, script, storage);
assert.equal(storage.getItem("hw-live:" + token), b64u(keyBytes));
await pause(600);
page = await runPage(`${base}/live/${token}`, script, storage);
assert.equal(page.els.head.textContent, "Sam is on bus 305");
assert.deepEqual(page.history.urls, [`/live/${token}#k=${b64u(keyBytes)}`]);

// MARK: the pure view, v1 and v2 (no relay)
const H = page.ctx.HWLive;
assert.ok(H && H.view, "the page's pure parts");
// (from the page's own realm: as plain values)
const plain = (x) => JSON.parse(JSON.stringify(x));
const Vw = (...a) => plain(H.view(...a)), Dc = (...a) => plain(H.decode(...a)), Sp = (...a) => plain(H.split(...a));
// stale: no update for over 3 minutes
let v = Vw({ ...state, t: now - 400 }, now - 400, now);
assert.equal(v.eyebrow.text, "Last seen " + hhmm(now - 400));
assert.equal(v.eyebrow.cls, "grey");
v = Vw({ ...state, t: now - 900 }, now - 900, now);
assert.match(v.age.text, /the phone may be out of reach/);
// v1 waiting and changing
v = Vw({ v: 1, name: "Sam", state: "waiting", mode: "train", line: "IC", num: "3512", from: "Eindhoven Centraal", to: "Breda", dep: now + 300, late: 2, t: now }, now, now);
assert.equal(v.head, "Sam is waiting for the IC 3512");
assert.equal(v.sub, `at Eindhoven Centraal · leaves ${hhmm(now + 300)} · 2 min late`);
assert.equal(v.timeline[0].title, "Waiting at Eindhoven Centraal");
v = Vw({ v: 1, name: "", state: "change", mode: "train", line: "IC", from: "Eindhoven Centraal", to: "Breda", dep: now + 180, t: now }, now, now);
assert.equal(v.head, "Your friend is changing at Eindhoven Centraal");
assert.equal(v.note, `IC to Breda leaves ${hhmm(now + 180)} (in 3 min)`);
assert.equal(v.face.letter, "Y");

// v2: the whole trip (synthetic): bus 305 → walk → IC → bus 1 → walk to the end
const trip = (over = {}) => ({
  v: 2, name: "Sam", face: "E8A33D", state: "riding", mode: "bus", line: "305", from: "Veghel, Busstation", to: "Eindhoven Centraal",
  dest: "Campus", eta: now + 960, end: now + 5400, late: 0, t: now - 12, inbox: true,
  pos: { lat: 51.55, lon: 5.45, at: now - 12, src: "gps" },
  leg: 0,
  legs: [
    { mode: "bus", line: "305", color: "E0632E", from: "Veghel, Busstation", to: "Eindhoven Centraal", dep: now - 360, arr: now + 960, late: 0 },
    { mode: "walk", from: "Eindhoven Centraal", to: "Eindhoven Centraal", dep: now + 960, arr: now + 1200, mins: 4 },
    { mode: "train", line: "IC", num: "3512", color: "3B44B0", from: "Eindhoven Centraal", to: "Breda", dep: now + 1500, arr: now + 3840, depPlatform: "4", arrPlatform: "6", coach: 3, deck: "upper" },
    { mode: "bus", line: "1", from: "Breda", to: "Breda, Hogeschool", dep: now + 4440, arr: now + 5220, depPlatform: "E" },
    { mode: "walk", from: "Breda, Hogeschool", to: "Campus", dep: now + 5220, arr: now + 5400, mins: 3 },
  ],
  shape: "_p~iF~ps|U_ulLnnqC_mqNvxq`@", // (Google's own example: three points)
  stops: [{ name: "Veghel, Busstation", t: now - 360, lat: 38.5, lon: -120.2 }, { name: "Rijksweg", t: now + 120, lat: 40.7, lon: -120.95 },
    { name: "Son", t: now + 500, lat: 41.0, lon: -121.5 }, { name: "Eindhoven Centraal", t: now + 960, lat: 43.252, lon: -126.453 }],
  next: 1,
  ...over,
});
assert.deepEqual(Dc("_p~iF~ps|U_ulLnnqC_mqNvxq`@"), [[-120.2, 38.5], [-120.95, 40.7], [-126.453, 43.252]]);
v = Vw(trip(), now, now);
assert.equal(v.eyebrow.text, "Live");
assert.equal(v.head, "Sam is on bus 305");
assert.equal(v.sub, "to Eindhoven Centraal · on time");
assert.equal(v.face.color, "#E8A33D");
assert.deepEqual(v.big, { place: "Eindhoven Centraal", time: hhmm(now + 960), sub: "in 16 min · 3 stops", then: { place: "Then Campus", time: hhmm(now + 5400) } });
assert.deepEqual(v.legs.map((x) => x.text), ["305", "🚶", "IC", "1", "🚶 Campus"]);
assert.deepEqual(v.legs.map((x) => x.state), ["cur", "next", "next", "next", "next"]);
assert.deepEqual(v.timeline.map((x) => [x.kind, x.time, x.title, x.sub]), [
  ["done", hhmm(now - 360), "Veghel, Busstation", "got on bus 305"],
  ["now", "now", "On bus 305", "Rijksweg · on time · GPS 12 s"],
  ["next", hhmm(now + 960), "Eindhoven Centraal", "change · walk 4 min to platform 4"],
  ["next", hhmm(now + 1500), "IC 3512 to Breda", "Eindhoven Centraal · platform 4 · coach 3, upper deck"],
  ["next", hhmm(now + 3840), "Breda", "change · to stop E"],
  ["next", hhmm(now + 4440), "Bus 1 to Breda, Hogeschool", "Breda · stop E"],
  ["next", hhmm(now + 5400), "Campus", "arrives · 3 min walk"],
]);
assert.equal(v.map.shape.length, 3);
assert.deepEqual(v.map.pos, [5.45, 51.55]);
assert.equal(v.map.label, "305");
assert.deepEqual(v.map.stops.map((x) => x.done), [true, false, false, false]);
assert.equal(v.map.dest.name, "Eindhoven Centraal");
assert.equal(v.msgs, true);
// the road split where the vehicle is
const [doneP, restP] = Sp([[0, 0], [0, 1], [0, 2]], [0.0001, 1.5]);
assert.equal(doneP.length, 3);
assert.ok(Math.abs(doneP[2][1] - 1.5) < 1e-9 && restP.length === 2);
// almost there: the next ride in the note
v = Vw(trip({ eta: now + 120, next: 3 }), now, now);
assert.equal(v.eyebrow.text, "Almost there");
assert.equal(v.eyebrow.cls, "almost");
assert.equal(v.head, "Arriving at Eindhoven Centraal");
assert.equal(v.sub, "next stop · in 2 min");
assert.equal(v.note, `Change to IC 3512 to Breda · platform 4 · leaves ${hhmm(now + 1500)} (23 min)`);
// at the change: waiting on the platform
v = Vw(trip({ state: "change", leg: 2, mode: "train", line: "IC", from: "Eindhoven Centraal", to: "Breda", dep: now + 180, late: 1,
  eta: now + 2520, pos: undefined, t: now + 1300 }), now + 1300, now + 1300);
assert.equal(v.eyebrow.text, "Changing");
assert.equal(v.head, "Sam is changing at Eindhoven Centraal");
assert.equal(v.note, "Waiting on platform 4 · IC 3512 leaves now");
v = Vw(trip({ state: "change", leg: 2, mode: "train", line: "IC", from: "Eindhoven Centraal", to: "Breda", dep: now + 1480, late: 1,
  eta: now + 3800, pos: undefined, t: now + 1300 }), now + 1300, now + 1300);
assert.equal(v.note, "Waiting on platform 4 · IC 3512 leaves in 3 min");
assert.deepEqual(v.big, { place: "Breda", time: hhmm(now + 3840), sub: "arrives · IC 3512", then: { place: "Then Campus", time: hhmm(now + 5400) } });
assert.deepEqual(v.legs.map((x) => x.state), ["done", "done", "cur", "next", "next"]);
assert.deepEqual(v.timeline.map((x) => [x.kind, x.title, x.sub]).slice(0, 3), [
  ["done", "Veghel, Busstation", "got on bus 305"],
  ["done", "Eindhoven Centraal", "got off · walking to platform 4"],
  ["now", "Waiting on platform 4", "IC 3512 to Breda leaves in 3 min · 1 min late"],
]);
// still walking there
v = Vw(trip({ state: "change", leg: 2, dep: now + 1500, eta: now + 3840, t: now + 1100 }), now + 1100, now + 1100);
assert.match(v.note, /^Walking 4 min to platform 4/);
// arrived
v = Vw(trip({ state: "arrived", to: "Campus", eta: now + 5340, pos: undefined, t: now + 5340 }), now + 5340, now + 5340);
assert.equal(v.eyebrow.text, "Arrived");
assert.equal(v.head, "Sam arrived");
assert.equal(v.sub, "Campus · " + hhmm(now + 5340));
assert.match(v.note, /link stops working soon/);
assert.equal(v.big, null);
assert.equal(v.age, null);
assert.ok(v.timeline.every((x) => x.kind === "done"));
assert.equal(v.map.pos, null);
// music: shown when fresh, only from the services it knows, covers only from their image hosts
const music = { title: "Night Song", artist: "The Bands", app: "Spotify", url: "https://open.spotify.com/track/abc", coverUrl: "https://i.scdn.co/image/xyz",
  at: new Date((now - 60) * 1000).toISOString() };
v = Vw(trip({ music }), now, now);
assert.deepEqual(v.music, { title: "Night Song", sub: "The Bands · Spotify", url: "https://open.spotify.com/track/abc", cover: "https://i.scdn.co/image/xyz" });
assert.equal(Vw(trip({ music: { ...music, at: new Date((now - 700) * 1000).toISOString() } }), now, now).music, null, "older than 10 min");
v = Vw(trip({ music: { ...music, url: "https://evil.example/x", coverUrl: "http://i.scdn.co/a" } }), now, now);
assert.equal(v.music.url, "");
assert.equal(v.music.cover, "");
assert.equal(Vw(trip({ music: { ...music, coverUrl: "https://is1-ssl.mzstatic.com/image/a.jpg", url: "https://music.apple.com/nl/song/1" } }), now, now).music.cover,
  "https://is1-ssl.mzstatic.com/image/a.jpg");
assert.equal(Vw(trip({ music: { ...music, title: "  " } }), now, now).music, null);

// MARK: v2 and messages through the relay
await pause(5200);
const v2 = trip({ t: now, music });
p = await put(secret, await lock(v2, keyBytes, token), now + 1800);
assert.equal(p.status, 200, JSON.stringify(p.json));
const ms = newStorage();
page = await runPage(link, script, ms);
assert.equal(page.els.head.textContent, "Sam is on bus 305");
assert.equal(page.els.music.hidden, false);
assert.equal(page.els.muTitle.textContent, "Night Song");
assert.equal(page.els.muOpen.hidden, false);
assert.equal(page.els.cover.children[0].src, "https://i.scdn.co/image/xyz");
assert.equal(page.els.legs.hidden, false);
assert.equal(page.els.tl.children.length, 7);
assert.equal(page.els.msg.hidden, false);
assert.equal(page.els.msgHead.textContent, "Send Sam a message");
assert.equal(page.els.chips.children.length, 4);
// a message from the page: locked with the link's key
page.els.msgName.value = "Kim";
page.els.msgText.value = "  On my way  ";
page.els.msgSend.click();
for (let i = 0; i < 60 && !ms.getItem("hw-live-sent:" + token); i++) await pause(50);
const sent = JSON.parse(ms.getItem("hw-live-sent:" + token));
assert.equal(sent.length, 1);
assert.equal(sent[0].seq, 1);
assert.equal(sent[0].text, "On my way");
assert.equal(ms.getItem("hw-live-name:" + token), "Kim");
assert.equal(page.els.msgText.value, "");
// one more at once: too soon (one per 10 s per network address and link)
page.els.msgText.value = "Again";
page.els.msgSend.click();
for (let i = 0; i < 60 && !page.els.msgInfo.textContent; i++) await pause(50);
assert.equal(page.els.msgInfo.textContent, "Wait a few seconds before sending another.");
// the sharer's phone: the next put says there's one; its inbox (with the secret) has it, locked
await pause(5200);
p = await put(secret, await lock(v2, keyBytes, token), now + 1800);
assert.equal(p.json.mseq, 1);
let ib = await post("/live/v1/inbox", { secret: b64u(secret), after: 0 });
assert.equal(ib.status, 200);
assert.equal(ib.json.mseq, 1);
assert.equal(ib.json.seen, 0);
assert.equal(ib.json.msgs.length, 1);
assert.ok(!JSON.stringify(ib.json).includes("my way"), "locked");
const msg = JSON.parse(await unseal(ib.json.msgs[0].data, keyBytes, "hw-live-msg-v1\n" + token));
assert.equal(msg.from, "Kim");
assert.equal(msg.fromKind, "web");
assert.equal(msg.text, "On my way");
assert.ok(Math.abs(msg.at - now) < 60);
assert.equal((await post("/live/v1/inbox", { secret: b64u(secret), after: 1 })).json.msgs.length, 0);
// another secret is another link: nothing there
assert.equal((await post("/live/v1/inbox", { secret: b64u(crypto.getRandomValues(new Uint8Array(32))), after: 0 })).status, 404);
assert.equal((await post("/live/v1/ack", { secret: b64u(secret), seq: -1 })).status, 400);
// a message doesn't open as a trip state (another AAD)
await assert.rejects(unseal(ib.json.msgs[0].data, keyBytes, "hw-live-v1\n" + token));
// seen, and an answer
const ack = await post("/live/v1/ack", { secret: b64u(secret), seq: 9 });
assert.deepEqual(ack.json, { ok: true, seen: 1 });
const reply = await seal({ text: "See you there", at: now + 30, re: 1 }, keyBytes, "hw-live-reply-v1\n" + token);
const rp = await post("/live/v1/reply", { secret: b64u(secret), data: b64u(reply) });
assert.equal(rp.status, 200, JSON.stringify(rp.json));
assert.equal(rp.json.seq, 1);
assert.equal((await post("/live/v1/reply", { secret: b64u(secret), data: b64u(reply) })).status, 429, "one answer per 5 s");
r = await call(`/live/v1/get?t=${token}`);
const g2 = await r.json();
assert.equal(g2.mseq, 1);
assert.equal(g2.seen, 1);
assert.equal(g2.replies.length, 1);
page = await runPage(link, script, ms, (els) => els.sent.children.length >= 2);
const lis = page.els.sent.children;
assert.equal(lis.length, 2);
assert.equal(lis[0].textContent, "On my waySeen ✓✓");
assert.equal(lis[1].className, "them");
assert.equal(lis[1].textContent, "See you thereSam · " + hhmm(now + 30));
// bad messages
assert.equal((await post(`/live/v1/msg?t=${token}`, { data: b64u(new Uint8Array(2049).fill(1)) })).status, 400, "at most 2 KB");
assert.equal((await post(`/live/v1/msg?t=${token}`, { data: "AAAA" })).status, 400);
assert.equal((await post("/live/v1/msg?t=short", { data: b64u(reply) })).status, 400);
if (!LIVE) {
  // at most 50 a link (from other addresses)
  const other = await liveToken(crypto.getRandomValues(new Uint8Array(32)));
  assert.equal((await post(`/live/v1/msg?t=${other}`, { data: b64u(reply) })).status, 404, "no link, no message");
  for (let i = 2; i <= 50; i++) {
    const st = (await post(`/live/v1/msg?t=${token}`, { data: b64u(reply) }, { "CF-Connecting-IP": "192.0.2." + i })).status;
    assert.equal(st, 200, "message " + i);
  }
  const full = await post(`/live/v1/msg?t=${token}`, { data: b64u(reply) }, { "CF-Connecting-IP": "198.51.100.1" });
  assert.equal(full.status, 429);
  assert.equal(full.json.error, "full");
  ib = await post("/live/v1/inbox", { secret: b64u(secret), after: 40 });
  assert.deepEqual(ib.json.msgs.map((m) => m.seq), [41, 42, 43, 44, 45, 46, 47, 48, 49, 50]);
  // one address: one per 10 s, at most 20 an hour (the clock moved on by hand)
  const core = new LiveCore({ storage: new FakeStorage() }, {});
  const t0 = Math.floor(now / 3600) * 3600 + 5;
  await core.store.put("s", { token: "x", created: t0, exp: t0 + 3500, at: t0, data: "x", hour: 0, puts: 0 });
  const realNow = Date.now;
  const codes = [];
  try {
    Date.now = () => t0 * 1000;
    codes.push((await core.msg({ data: "x", ip: "same" })).status);
    Date.now = () => (t0 + 5) * 1000;
    codes.push((await core.msg({ data: "x", ip: "same" })).status);
    for (let i = 1; i <= 22; i++) {
      Date.now = () => (t0 + i * 11) * 1000;
      codes.push((await core.msg({ data: "x", ip: "same" })).status);
    }
  } finally { Date.now = realNow; }
  assert.deepEqual(codes.slice(0, 2), [200, 429], "10 s apart");
  assert.equal(codes.filter((c) => c === 200).length, 20, "20 an hour");
}

// MARK: the map at a change: the sharer, the stop, the next rides (pure)
{
  const enc = (pts) => { let out = "", pl = 0, pn = 0; for (const [lon, lat] of pts) { for (const [v, p] of [[Math.round(lat * 1e5), pl], [Math.round(lon * 1e5), pn]]) {
    let d = v - p; d = d < 0 ? ~(d << 1) : d << 1; while (d >= 0x20) { out += String.fromCharCode((0x20 | (d & 0x1f)) + 63); d >>= 5; } out += String.fromCharCode(d + 63); }
    pl = Math.round(lat * 1e5); pn = Math.round(lon * 1e5); } return out; };
  assert.deepEqual(Dc(enc([[5.1, 51.2], [5.3, 51.4]])), [[5.1, 51.2], [5.3, 51.4]]);
  const at = { state: "change", leg: 2, mode: "train", line: "IC", from: "Eindhoven Centraal", to: "Breda", dep: now + 1480, eta: now + 3800, t: now + 1300,
    pos: { lat: 51.4425, lon: 5.4770, at: now + 1290, src: "phone" }, next: 0, shape: undefined,
    stops: [{ name: "Eindhoven Centraal", lat: 51.44306, lon: 5.47901 }, { name: "Tilburg", lat: 51.5606, lon: 5.0836 }, { name: "Breda", lat: 51.5955, lon: 4.7800 }] };
  const legs = trip().legs.map((l, i) => i === 3 ? { ...l, shape: enc([[4.7810, 51.5950], [4.7900, 51.5800], [4.8000, 51.5700]]) } : l);
  v = Vw(trip({ ...at, legs }), now + 1300, now + 1300);
  assert.equal(v.eyebrow.text, "Changing");
  // the sharer (their phone) as a dot with their initial, not as the vehicle
  assert.deepEqual(v.map.person, { pos: [5.477, 51.4425], letter: "S", color: "#E8A33D" });
  assert.equal(v.map.pos, null);
  // the walk to the stop (dotted), the stop they wait at as a ring, the IC's road, then bus 1's own road
  assert.deepEqual(v.map.walks[0], [[5.477, 51.4425], [5.47901, 51.44306]]);
  assert.deepEqual(v.map.rings[0], [5.47901, 51.44306]);
  assert.equal(v.map.road.length, 3);
  assert.equal(v.map.later.length, 1, "bus 1");
  assert.deepEqual(v.map.walks[1], [[4.78, 51.5955], [4.781, 51.595]], "the walk at Breda");
  assert.equal(v.map.later[0].color, "#E0632E");
  assert.equal(v.map.later[0].dashed, false);
  assert.deepEqual(v.map.later[0].coords[0], [4.781, 51.595]);
  assert.deepEqual(v.map.rings.slice(1), [[4.781, 51.595]], "the change at Breda");
  assert.deepEqual(v.map.dest, { lon: 4.8, lat: 51.57, name: "Breda, Hogeschool" });
  // framed together: the sharer, the IC's road and bus 1's
  assert.ok(v.map.all.some((p) => p[0] === 5.477) && v.map.all.some((p) => p[0] === 4.8));
  // the vehicle's own GPS at a change: the vehicle, and the stop still ringed
  v = Vw(trip({ ...at, legs, pos: { lat: 51.50, lon: 5.30, at: now + 1290, src: "gps" } }), now + 1300, now + 1300);
  assert.equal(v.map.person, null);
  assert.deepEqual(v.map.pos, [5.3, 51.5]);
  assert.equal(v.map.label, "IC");
  assert.deepEqual(v.map.rings[0], [5.47901, 51.44306]);
  // a later ride with no road: dashed across it, in its colour
  v = Vw(trip({ ...at, legs: [...trip().legs.slice(0, 3), { ...trip().legs[3] }, { mode: "bus", line: "9", from: "x", to: "Campus", shape: enc([[4.9, 51.6], [4.95, 51.62]]) }] }), now + 1300, now + 1300);
  assert.equal(v.map.later[0].dashed, true);
  assert.equal(v.map.later[0].color, "#E0632E");
  assert.deepEqual(v.map.later[0].coords, [[4.78, 51.5955], [4.9, 51.6]]);
  assert.equal(v.map.dest.name, "Campus");
  // each leg's own "shape" (the apps send them from iOS 0.42.10 and Android 0.10.8): at a change with no stops, the next ride's road
  // from its leg; a walk's as dots; a ride known only from where to where as a dashed straight line; the end of the walk
  const pl = trip().legs.map((l) => ({ ...l }));
  pl[1].shape = enc([[5.47901, 51.44306], [5.4795, 51.4428]]);
  pl[2].shape = enc([[5.4795, 51.4428], [5.0836, 51.5606], [4.78, 51.5955]]);
  pl[3].shape = enc([[4.781, 51.595], [4.8, 51.57]]);
  pl[4].shape = enc([[4.8, 51.57], [4.802, 51.5695]]);
  v = Vw(trip({ ...at, legs: pl, stops: undefined, shape: undefined, pos: undefined }), now + 1300, now + 1300);
  assert.equal(v.map.road.length, 3, "the IC's road from its leg");
  assert.deepEqual(v.map.walks[0], [[5.47901, 51.44306], [5.4795, 51.4428]], "the walk to the platform, still to come");
  assert.deepEqual(v.map.rings[0], [5.4795, 51.4428]);
  assert.deepEqual(v.map.later.map((x) => x.dashed), [true]);
  assert.deepEqual(v.map.dest, { lon: 4.802, lat: 51.5695, name: "Campus" });
  // riding: the phone's fix is inside the vehicle (its pill), no person dot
  v = Vw(trip({ pos: { lat: 51.55, lon: 5.45, at: now - 12, src: "phone" } }), now, now);
  assert.equal(v.map.person, null);
  assert.deepEqual(v.map.pos, [5.45, 51.55]);
  assert.equal(v.map.later.length, 0, "no later road known");
  assert.equal(v.pic, 0);
  assert.equal(Vw(trip({ pic: 3 }), now, now).pic, 3);
}

// MARK: the page's layout: a sheet whose header is the drag area; the music strip inside the card, under the name
{
  const card = html.slice(html.indexOf('<main id="card"'), html.indexOf("</main>"));
  const head = card.slice(card.indexOf('<div id="shead"'), card.indexOf('<div id="sbody"'));
  assert.ok(head.includes('id="grab"') && head.includes('id="head"') && head.includes('id="face"'), "handle and name row drag the sheet");
  assert.ok(card.indexOf('id="music"') > card.indexOf('id="sbody"'), "the music strip is in the card's body");
  assert.ok(card.indexOf('id="music"') < card.indexOf('id="big"'), "under the name, above the big time");
  assert.ok(card.includes('id="sfoot"') && card.indexOf('id="msgText"') > card.indexOf('id="sfoot"'), "the message box at the sheet's bottom");
  // nothing floats over the map but the (i), "Open in Haltewekker" and "⌖"; all below the browser's own bar
  const fixed = [...html.matchAll(/(?:^|[}\n])([.#][\w-]+)\{[^}]*position:fixed/g)].map((m) => m[1]);
  assert.deepEqual(fixed.sort(), ["#map", ".ghost", ".pill", ".sheet"]);
  assert.match(html, /\.pill\{position:fixed;top:max\(14px,calc\(env\(safe-area-inset-top\) \+ 10px\)\)/);
  assert.match(html, /\.maplibregl-ctrl-top-left\{top:max\(14px,calc\(env\(safe-area-inset-top\) \+ 10px\)\)/);
  assert.match(html, /body\{position:fixed;inset:0;/);
  assert.match(html, /\.shead\{[^}]*min-height:56px[^}]*touch-action:none/);
  assert.match(html, /\.sheet\.full \.sbody\{overflow-y:auto;touch-action:pan-y/);
  assert.match(html, /92dvh/);
  assert.match(script, /visualViewport/);
}

// MARK: the sharer's picture (locked with the link's key; its own AAD)
{
  const faceAad = "hw-live-face-v1\n" + token;
  const jpg = new Uint8Array(9000).map((_, i) => (i * 7) & 255); jpg[0] = 0xff; jpg[1] = 0xd8;
  const sealedFace = await seal(jpg, keyBytes, faceAad);
  const fput = (sec, data, method = "PUT") => call("/live/v1/face", { method, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ secret: b64u(sec), data: b64u(data) }) });
  assert.equal((await call(`/live/v1/face?t=${token}`)).status, 404, "none yet");
  assert.equal((await fput(new Uint8Array(16), sealedFace)).status, 400, "a bad secret");
  assert.equal((await fput(crypto.getRandomValues(new Uint8Array(32)), sealedFace)).status, 404, "another secret: no such link");
  assert.equal((await fput(secret, new Uint8Array(24 * 1024 + 1).fill(1))).status, 400, "at most 24 KB");
  assert.equal((await fput(secret, new Uint8Array([2, ...sealedFace.slice(1)]))).status, 400, "first byte 1");
  assert.equal((await call(`/live/v1/face?t=${token}`, { method: "DELETE" })).status, 405);
  const fp = await fput(secret, sealedFace);
  assert.equal(fp.status, 200);
  const etag = (await fp.json()).etag;
  assert.match(etag, /^[0-9a-f]{32}$/);
  assert.equal((await fput(secret, sealedFace, "POST")).status, 429, "5 s apart");
  r = await call(`/live/v1/face?t=${token}&v=1`);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("Content-Type"), "application/octet-stream");
  assert.equal(r.headers.get("ETag"), `"${etag}"`);
  assert.match(r.headers.get("Cache-Control"), /max-age=86400/);
  const box = new Uint8Array(await r.arrayBuffer());
  assert.deepEqual(box, sealedFace, "only the locked bytes");
  assert.equal((await call(`/live/v1/face?t=${token}&v=1`, { headers: { "If-None-Match": `"${etag}"` } })).status, 304);
  // opened only as a picture: not with the trip's AAD, and a trip state doesn't open as a picture
  const k = await crypto.subtle.importKey("raw", keyBytes, { name: "AES-GCM" }, false, ["decrypt"]);
  const openAs = (b, aad) => crypto.subtle.decrypt({ name: "AES-GCM", iv: b.slice(1, 13), additionalData: new TextEncoder().encode(aad) }, k, b.slice(13));
  assert.deepEqual(new Uint8Array(await openAs(box, faceAad)), jpg);
  await assert.rejects(openAs(box, "hw-live-v1\n" + token));
  await assert.rejects(openAs(await lock(v2, keyBytes, token), faceAad));
  assert.ok(script.includes("hw-live-face-v1"), "the page opens it with the same AAD");
}

// arrived (the app's last state), then ended
await pause(5200);
const arrived = { ...state, state: "arrived", eta: now + 60, pos: undefined, late: undefined, t: now + 60 };
p = await put(secret, await lock(arrived, keyBytes, token), now + 900);
assert.equal(p.status, 200, JSON.stringify(p.json));
page = await runPage(link, script);
assert.equal(page.els.head.textContent, "Sam arrived");
assert.equal(page.els.eyebrow.textContent, "Arrived");
assert.equal(page.els.sub.textContent, "Den Bosch · " + hhmm(arrived.eta));
assert.match(page.els.note.textContent, /stops working soon/);
const e = await end(secret);
assert.equal(e.status, 200);
assert.equal((await end(secret)).status, 200, "ending twice is fine");
r = await call(`/live/v1/get?t=${token}`);
assert.equal(r.status, 410);
if (!LIVE) {
  const left = [...env.LIVE.objects.get("t:" + token).store.map.keys()];
  assert.deepEqual(left, ["s"], "the messages and the picture go with the link");
}
assert.equal((await post(`/live/v1/msg?t=${token}`, { data: b64u(reply) }, LIVE ? {} : { "CF-Connecting-IP": "203.0.113.9" })).status, 410);
assert.equal((await post("/live/v1/inbox", { secret: b64u(secret), after: 0 })).status, 410);
assert.equal((await call(`/live/v1/face?t=${token}`)).status, 410, "the picture goes with the link");
page = await runPage(link, script, storage);
assert.equal(page.els.head.textContent, "This link has ended");
assert.equal(page.els.eyebrow.textContent, "Ended");
assert.equal(page.els.msg.hidden, true);
assert.equal(storage.getItem("hw-live:" + token), null, "the kept key goes with the link");
page = await runPage(`${base}/live/${token}`, script);
for (let i = 0; i < 60 && page.els.head.textContent !== "This link has ended"; i++) await pause(50);
assert.equal(page.els.head.textContent, "This link has ended", "no key, and ended: ended");
await pause(5200);
assert.equal((await put(secret, await lock(state, keyBytes, token), now + 900)).status, 410, "an ended link stays ended");
assert.equal((await call("/live/v1/nothing")).status, 404);

// MARK: the shared test vector (docs/live-link-vectors.json), as the apps lock it, opened and drawn by the page
let vec = null;
try { vec = JSON.parse(readFileSync(new URL("../docs/live-link-vectors.json", import.meta.url), "utf8")); } catch {}
if (vec) {
  const key = Buffer.from(vec.key, "base64url");
  const vt = await liveToken(Buffer.from(vec.secret, "base64url"));
  assert.equal(vt, vec.token);
  for (const [name, aad] of [["state", "hw-live-v1\n"], ["message", "hw-live-msg-v1\n"], ["appMessage", "hw-live-msg-v1\n"], ["reply", "hw-live-reply-v1\n"]]) {
    const x = vec[name];
    assert.equal(await unseal(x.data, key, aad + vt), x.plain, name);
    assert.equal(b64u(await seal(x.plain, key, aad + vt, Buffer.from(x.nonce, "hex"))), x.data, name + " sealed byte for byte");
  }
  const s = JSON.parse(vec.state.plain);
  v = Vw(s, s.t, s.t);
  assert.equal(v.head, vec.page.head);
  assert.equal(v.sub, vec.page.sub);
  assert.deepEqual(v.legs.map((x) => x.text), vec.page.legs);
  assert.deepEqual(v.timeline.map((x) => x.title), vec.page.timeline);
  assert.equal(v.map.shape.length, vec.page.shapePoints);
  // (Android 0.10.8, iOS 0.42.10) at a change: each leg's own road, the phone, the picture's version; the picture itself
  if (vec.state2) {
    assert.equal(await unseal(vec.state2.data, key, "hw-live-v1\n" + vt), vec.state2.plain);
    assert.equal(b64u(await seal(vec.state2.plain, key, "hw-live-v1\n" + vt, Buffer.from(vec.state2.nonce, "hex"))), vec.state2.data);
    const s2 = JSON.parse(vec.state2.plain);
    v = Vw(s2, s2.t, s2.t);
    assert.equal(v.head, vec.page2.head);
    assert.equal(v.note, vec.page2.note);
    assert.equal(v.pic, 2);
    assert.deepEqual(v.map.person.pos, [s2.pos.lon, s2.pos.lat]);
    assert.ok(v.map.road.length > 2 && v.map.road.length <= 80, "the IC's road from its leg");
    assert.equal(v.map.later.length, 1);
    assert.equal(v.map.later[0].dashed, false, "bus 1's own road");
    assert.equal(v.map.dest.name, "Campus");
    assert.ok(v.map.walks.length >= 2, "the walk to Campus, and from the sharer to the platform");
    assert.equal(b64u(await seal(Buffer.from(vec.face.plain, "base64url"), key, "hw-live-face-v1\n" + vt, Buffer.from(vec.face.nonce, "hex"))), vec.face.data);
    await assert.rejects(unseal(vec.face.data, key, "hw-live-v1\n" + vt));
    console.log("live links: the shared change vector and the picture open and draw");
  }
  console.log("live links: the shared test vector opens and draws");
}

if (LIVE) {
  const ns = await fetch(LIVE + "/ns/departures?station=BD");
  assert.equal(ns.status, 200, "NS departures still answer");
  const st = await fetch(LIVE + "/f/v1/status");
  assert.equal(st.status, 200);
  console.log("live relay: NS departures", ns.status, "· friends status", st.status);
}
console.log("live links: all checks passed", LIVE ? "(live)" : "(local)");
