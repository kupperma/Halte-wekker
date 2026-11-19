// Haltewekker live links (0.30): a web page with your trip's live times for someone without the app (a parent).
//
// The phone makes a link   https://<relay>/live/<token>#<key>
//   secret = 32 random bytes (only the phone has it: it lets it write);  key = 32 more random bytes (AES-256-GCM)
//   token  = base64url(first 16 bytes of SHA-256("hw-live-token-v1" + secret))  (22 characters)
// and, on the ride's network tick, posts the trip's state locked with the key:
//   data = 0x01 | nonce (12) | AES-256-GCM ciphertext | tag (16), AAD "hw-live-v1\n" + token
// The key is only in the link's fragment (after the #), which a browser never sends: the relay holds only locked
// bytes it can't read, and forgets everything when the link ends. Nothing here logs a token, a secret or the data.
//
// Routes:
//   POST /live/v1/put  {"secret": b64url(32), "data": b64url(≤ 4 KB), "until": unix s}  -> {"ok":true,"token","exp"}
//                      the first put makes the link (at most 20 new links an hour per network address, hashed);
//                      it ends at `until`, never later than 4 hours after it was made; a later put may move `until`
//                      within that. Puts at least 5 s apart, at most 240 an hour per link. 410 "ended" once ended.
//   POST /live/v1/end  {"secret"}                -> {"ok":true}: the data goes at once, the page says it ended
//   GET  /live/v1/get?t=<token>                  -> {"data","at","exp"} | 410 {"error":"ended"} | 404 {"error":"gone"}
//   GET  /live/<token>                           the page (it reads the key from the fragment and decrypts there)
//   GET  /live/app.js                            the page's script (same origin: no script from anywhere else)
// One Durable Object per link (SQLite-backed, its key-value storage), named "t:<token>"; "ip:<hash>" counts new links.

const MAX_AGE = 4 * 3600;                 // a link lives at most this long after it was made
const MAX_DATA = 4096;                    // one state, decoded
const MAX_BODY = 16 * 1024;               // one request
const MIN_GAP = 5;                        // seconds between two puts
const PUTS_PER_HOUR = 240;
const GETS_PER_MIN = 120;                 // per link, all viewers together
const NEW_PER_HOUR_PER_IP = 20;
const TOKEN = /^[A-Za-z0-9_-]{22}$/;
const B64URL = /^[A-Za-z0-9_-]*={0,2}$/;

const enc = new TextEncoder();
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const json = (o, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
const fail = (error, status) => json({ error }, status);

function b64urlDecode(s) {
  if (typeof s !== "string" || !B64URL.test(s)) return null;
  const t = s.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  try {
    const bin = atob(t + "===".slice((t.length + 3) % 4));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch { return null; }
}
function b64urlEncode(bytes) {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// The link's token for a secret (32 bytes).
export async function liveToken(secret) {
  const pre = enc.encode("hw-live-token-v1");
  const all = new Uint8Array(pre.length + secret.length);
  all.set(pre, 0); all.set(secret, pre.length);
  return b64urlEncode(new Uint8Array(await crypto.subtle.digest("SHA-256", all)).slice(0, 16));
}

const now = () => Math.floor(Date.now() / 1000);

/// The Worker's part: the shape of a request, then the link's own Durable Object.
export async function live(request, env, url) {
  const path = url.pathname;
  if (path === "/live/app.js") {
    if (request.method !== "GET") return fail("method", 405);
    return new Response(APP_JS, { headers: { "Content-Type": "text/javascript; charset=utf-8", "Cache-Control": "max-age=300",
      "X-Content-Type-Options": "nosniff" } });
  }
  if (path === "/live/v1/get") {
    if (request.method !== "GET") return fail("method", 405);
    const t = url.searchParams.get("t") || "";
    if (!TOKEN.test(t)) return fail("bad_token", 400);
    if (!env.LIVE) return fail("no_storage", 503);
    return link(env, t).fetch("https://do/get", { method: "POST" });
  }
  if (path === "/live/v1/put" || path === "/live/v1/end") {
    if (request.method !== "POST") return fail("method", 405);
    if (!env.LIVE) return fail("no_storage", 503);
    if (Number(request.headers.get("Content-Length") || "0") > MAX_BODY) return fail("too_big", 413);
    const raw = await request.arrayBuffer();
    if (raw.byteLength > MAX_BODY) return fail("too_big", 413);
    let input;
    try { input = JSON.parse(new TextDecoder().decode(raw)); } catch { return fail("bad_json", 400); }
    if (typeof input !== "object" || input === null || Array.isArray(input)) return fail("bad_json", 400);
    const secret = b64urlDecode(input.secret);
    if (!secret || secret.length !== 32) return fail("bad_secret", 400);
    const token = await liveToken(secret);
    const stub = link(env, token);
    if (path === "/live/v1/end") return stub.fetch("https://do/end", { method: "POST" });
    const data = b64urlDecode(input.data);
    if (!data || data.length < 1 + 12 + 16 || data.length > MAX_DATA || data[0] !== 1) return fail("bad_data", 400);
    if (!Number.isInteger(input.until)) return fail("bad_until", 400);
    const body = JSON.stringify({ token, data: input.data, until: input.until });
    let r = await stub.fetch("https://do/put", { method: "POST", body });
    if (r.status === 428) {
      // a new link: counted per network address (hashed, kept an hour)
      const ip = request.headers.get("CF-Connecting-IP") || "unknown";
      const ipKey = hex(await crypto.subtle.digest("SHA-256", enc.encode("hw-live-ip-v1:" + ip))).slice(0, 32);
      const g = await env.LIVE.get(env.LIVE.idFromName("ip:" + ipKey)).fetch("https://do/gate", { method: "POST" });
      if (g.status !== 200) return fail("slow_down", 429);
      r = await stub.fetch("https://do/put", { method: "POST", body, headers: { "X-Live-New": "1" } });
    }
    return r;
  }
  const m = path.match(/^\/live\/([A-Za-z0-9_-]{22})\/?$/);
  if (m && (request.method === "GET" || request.method === "HEAD")) return page();
  return fail("not_found", 404);
}

const link = (env, token) => env.LIVE.get(env.LIVE.idFromName("t:" + token));

/// One live link (named "t:<token>") or one network address's counter of new links ("ip:<hash>").
export class LiveCore {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.store = ctx.storage;
    this.minute = 0;
    this.gets = 0;
  }

  async fetch(request) {
    try {
      const p = new URL(request.url).pathname;
      if (p === "/put") return await this.put(await request.json(), request.headers.get("X-Live-New") === "1");
      if (p === "/end") return await this.end();
      if (p === "/get") return await this.get();
      if (p === "/gate") return await this.gate();
      return fail("not_found", 404);
    } catch (e) {
      return fail("relay_error", 500);
    }
  }

  async slot() {
    const s = await this.store.get("s");
    if (s && now() >= s.exp) { await this.wipe(); return null; }
    return s || null;
  }

  async put({ token, data, until }, gated) {
    const t = now();
    let s = await this.slot();
    if (s && s.ended) return fail("ended", 410);
    if (!s) {
      if (!gated) return fail("gate", 428);
      s = { token, created: t, exp: t, at: 0, data: null, ended: null, hour: 0, puts: 0 };
    } else if (t - s.at < MIN_GAP) {
      return fail("slow_down", 429);
    }
    const hour = Math.floor(t / 3600);
    if (s.hour !== hour) { s.hour = hour; s.puts = 0; }
    if (s.puts >= PUTS_PER_HOUR) return fail("slow_down", 429);
    if (until < t + 30) return fail("bad_until", 400);
    s.puts += 1;
    s.exp = Math.min(until, s.created + MAX_AGE);
    s.at = t;
    s.data = data;
    await this.store.put("s", s);
    await this.store.setAlarm((s.exp + 5) * 1000);
    return json({ ok: true, token: s.token, exp: s.exp });
  }

  async end() {
    const s = await this.slot();
    if (s && !s.ended) {
      // (kept, without the data, until it would have ended: so the page can say it ended)
      s.ended = now();
      s.data = null;
      s.exp = Math.max(s.created + MAX_AGE, now() + 60);
      await this.store.put("s", s);
      await this.store.setAlarm((s.exp + 5) * 1000);
    }
    return json({ ok: true });
  }

  async get() {
    const s = await this.slot();
    if (!s) return fail("gone", 404);
    // (counted in memory: a view writes nothing)
    const minute = Math.floor(now() / 60);
    if (this.minute !== minute) { this.minute = minute; this.gets = 0; }
    this.gets += 1;
    if (this.gets > GETS_PER_MIN) return fail("slow_down", 429);
    if (s.ended || !s.data) return fail("ended", 410);
    return json({ data: s.data, at: s.at, exp: s.exp });
  }

  async gate() {
    const hour = Math.floor(now() / 3600);
    const g = (await this.store.get("g")) || { hour, n: 0 };
    if (g.hour !== hour) { g.hour = hour; g.n = 0; }
    g.n += 1;
    await this.store.put("g", g);
    await this.store.setAlarm((hour + 1) * 3600 * 1000 + 60000);
    return g.n > NEW_PER_HOUR_PER_IP ? fail("slow_down", 429) : json({ ok: true });
  }

  async wipe() {
    await this.store.deleteAlarm();
    await this.store.deleteAll();
  }

  async alarm() {
    const s = await this.store.get("s");
    if (s && now() < s.exp) { await this.store.setAlarm((s.exp + 5) * 1000); return; }
    const g = await this.store.get("g");
    if (!s && g && g.hour === Math.floor(now() / 3600)) { await this.store.setAlarm((g.hour + 1) * 3600 * 1000 + 60000); return; }
    await this.wipe();
  }
}

// MARK: the page

const CSP = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src https://tile.openstreetmap.org; " +
  "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

function page() {
  return new Response(PAGE, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": CSP,
      // (the map's tiles see only the relay's name, never the link)
      "Referrer-Policy": "strict-origin",
      "X-Content-Type-Options": "nosniff",
      "X-Robots-Tag": "noindex, nofollow",
    },
  });
}

const PAGE = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="strict-origin"><title>Live trip · Haltewekker</title>
<style>
:root{color-scheme:light dark;--bg:#F1F3F5;--card:#fff;--text:#14171A;--sub:#5B636B;--accent:#0E7A55;--soft:#E3F2EC;--warn:#B25E00;--line:#DDE1E5}
@media (prefers-color-scheme:dark){:root{--bg:#111417;--card:#1C1F23;--text:#ECEEF0;--sub:#A3ABB3;--accent:#3DD69B;--soft:#16342A;--warn:#FFB45C;--line:#2B3035}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:17px/1.45 -apple-system,system-ui,"Segoe UI",Roboto,sans-serif;-webkit-text-size-adjust:100%}
main{max-width:520px;margin:0 auto;padding:28px 16px 40px}
.card{background:var(--card);border-radius:24px;padding:20px}
.eyebrow{margin:0 0 6px;font-size:13px;font-weight:600;letter-spacing:.02em;color:var(--accent);text-transform:uppercase}
h1{font-size:24px;line-height:1.25;margin:0 0 8px;overflow-wrap:anywhere}
p{margin:0 0 8px;color:var(--sub);overflow-wrap:anywhere}
.badge{display:inline-block;background:var(--soft);color:var(--accent);font-weight:600;font-size:15px;border-radius:999px;padding:4px 12px;margin:4px 0 8px}
.badge.end{background:var(--line);color:var(--sub)}
.age{color:var(--warn)}
#map{position:relative;height:220px;margin-top:12px;border-radius:16px;overflow:hidden;background:var(--line)}
#tiles img{position:absolute;width:256px;height:256px;max-width:none}
.dot{position:absolute;left:50%;top:50%;width:18px;height:18px;margin:-9px 0 0 -9px;border-radius:50%;background:var(--accent);
border:3px solid #fff;box-shadow:0 0 0 6px rgba(14,122,85,.25)}
.osm{position:absolute;right:6px;bottom:6px;font-size:11px;background:rgba(255,255,255,.85);color:#333;padding:1px 6px;border-radius:6px;text-decoration:none}
.foot{font-size:13px;margin-top:16px;padding:0 4px}
</style></head><body><main>
<div class="card" aria-live="polite">
<p class="eyebrow">Live trip</p>
<h1 id="head">Opening the trip…</h1>
<div id="badge" hidden></div>
<p id="detail" hidden></p>
<p id="age" class="age" hidden></p>
<div id="map" hidden aria-hidden="true"><div id="tiles"></div><div class="dot"></div>
<a class="osm" href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener noreferrer">© OpenStreetMap</a></div>
<noscript><p>Turn on JavaScript to see the trip.</p></noscript>
</div>
<p class="foot">Only people with this link can see this trip. It ends when the trip does (at most 4 hours). The trip is locked
with a key that is only in the link (after the #), so the relay that passes it on can’t read it. Made with Haltewekker.</p>
</main><script src="/live/app.js"></script></body></html>`;

const APP_JS = `(function () {
  "use strict";
  var token = (location.pathname.split("/")[2] || "").replace(/\\/$/, "");
  var keyText = location.hash.slice(1);
  var key = null, timer = null, over = false, lastPos = null, errors = 0;
  function $(id) { return document.getElementById(id); }
  function show(id, text) { var e = $(id); if (text) { e.textContent = text; e.hidden = false; } else { e.hidden = true; } }
  function b64u(s) {
    if (!/^[A-Za-z0-9_-]+={0,2}$/.test(s)) return null;
    s = s.replace(/=+$/, "").replace(/-/g, "+").replace(/_/g, "/");
    while (s.length % 4) s += "=";
    var b = atob(s), u = new Uint8Array(b.length);
    for (var i = 0; i < b.length; i++) u[i] = b.charCodeAt(i);
    return u;
  }
  function two(n) { return (n < 10 ? "0" : "") + n; }
  function hhmm(t) { var d = new Date(t * 1000); return two(d.getHours()) + ":" + two(d.getMinutes()); }
  function vehicle(s) {
    var line = String(s.line || "").trim(), num = String(s.num || "").trim(), mode = String(s.mode || "bus");
    if (mode === "train") return line ? "the " + (num ? line + " " + num : line) : "the train";
    return line ? mode + " " + line : "the " + mode;
  }
  function late(s) {
    if (typeof s.late !== "number") return "";
    return s.late >= 1 ? " \\u00b7 " + s.late + " min late" : " \\u00b7 on time";
  }
  function stage(s) { return ["waiting", "riding", "change", "arrived"].indexOf(s.state) >= 0 ? s.state : "riding"; }
  function headline(s) {
    var n = String(s.name || "").trim() || "Your friend", v = vehicle(s), st = stage(s);
    var to = s.to ? " to " + s.to : "";
    if (st === "arrived") return n + " has arrived" + (s.to ? " at " + s.to : "") + (s.eta ? " \\u00b7 " + hhmm(s.eta) : "");
    if (st === "waiting") return n + " is waiting for " + v + to + (s.from ? " at " + s.from : "") + (s.dep ? " \\u00b7 leaves " + hhmm(s.dep) : "") + late(s);
    if (st === "change") return n + " is changing" + (s.from ? " at " + s.from : "") + (s.line ? " \\u00b7 then " + v + to + (s.dep ? " at " + hhmm(s.dep) : "") : "");
    return n + " is on " + v + to + (s.eta ? " \\u00b7 arrives " + hhmm(s.eta) : "") + late(s);
  }
  function detail(s) {
    if (stage(s) === "arrived" || !s.dest || s.dest === s.to) return "";
    return "Then on to " + s.dest + (s.end ? " \\u00b7 there around " + hhmm(s.end) : "");
  }
  function ended(text) {
    over = true;
    clearTimeout(timer);
    show("head", text);
    var b = $("badge"); b.className = "badge end"; b.textContent = "Ended"; b.hidden = false;
    show("detail", ""); show("age", ""); $("map").hidden = true;
  }
  function map(p) {
    var box = $("map");
    if (!p || typeof p.lat !== "number" || typeof p.lon !== "number") { box.hidden = true; return; }
    box.hidden = false;
    if (lastPos && Math.abs(lastPos.lat - p.lat) < 0.0001 && Math.abs(lastPos.lon - p.lon) < 0.0001) return;
    lastPos = p;
    var z = 15, n = Math.pow(2, z), w = box.clientWidth || 320, h = box.clientHeight || 220;
    var lat = Math.max(-85, Math.min(85, p.lat)) * Math.PI / 180;
    var px = (p.lon + 180) / 360 * n * 256;
    var py = (1 - Math.log(Math.tan(lat) + 1 / Math.cos(lat)) / Math.PI) / 2 * n * 256;
    var left = px - w / 2, top = py - h / 2, tiles = $("tiles");
    tiles.textContent = "";
    for (var tx = Math.floor(left / 256); tx <= Math.floor((left + w) / 256); tx++) {
      for (var ty = Math.floor(top / 256); ty <= Math.floor((top + h) / 256); ty++) {
        if (ty < 0 || ty >= n) continue;
        var img = document.createElement("img");
        img.alt = ""; img.decoding = "async"; img.referrerPolicy = "strict-origin";
        img.src = "https://tile.openstreetmap.org/" + z + "/" + (((tx % n) + n) % n) + "/" + ty + ".png";
        img.style.left = Math.round(tx * 256 - left) + "px";
        img.style.top = Math.round(ty * 256 - top) + "px";
        tiles.appendChild(img);
      }
    }
  }
  function render(s, relayAt) {
    var head = headline(s);
    show("head", head);
    document.title = head.split(" \\u00b7 ")[0] + " \\u00b7 Haltewekker";
    var b = $("badge");
    if (stage(s) === "arrived") { b.className = "badge"; b.textContent = "Arrived"; b.hidden = false; } else { b.hidden = true; }
    show("detail", detail(s));
    var t = Math.min(typeof s.t === "number" ? s.t : relayAt, relayAt || s.t), age = Date.now() / 1000 - t;
    show("age", stage(s) !== "arrived" && age > 150 ? "Last update " + hhmm(t) + (age > 600 ? " \\u00b7 the phone may be out of reach" : "") : "");
    map(stage(s) === "arrived" ? null : s.pos);
  }
  function next(ms) { clearTimeout(timer); if (!over && document.visibilityState !== "hidden") timer = setTimeout(poll, ms); }
  function poll() {
    fetch("/live/v1/get?t=" + encodeURIComponent(token), { cache: "no-store" }).then(function (r) {
      if (r.status === 404 || r.status === 410) { ended("This link has ended"); return null; }
      if (r.status === 429) { next(30000); return null; }
      if (!r.ok) throw new Error("status " + r.status);
      return r.json();
    }).then(function (j) {
      if (!j) return;
      var box = b64u(j.data || "");
      if (!box || box.length < 29 || box[0] !== 1) throw new Error("bad box");
      return crypto.subtle.decrypt({ name: "AES-GCM", iv: box.slice(1, 13), additionalData: new TextEncoder().encode("hw-live-v1\\n" + token), tagLength: 128 },
        key, box.slice(13)).then(function (plain) {
        errors = 0;
        render(JSON.parse(new TextDecoder().decode(plain)), j.at);
        next(15000);
      }, function () { ended("This link’s key doesn’t fit. Ask for the link again."); });
    }).catch(function () {
      errors += 1;
      if (errors >= 2) show("age", "Can’t reach the trip right now. Trying again…");
      next(Math.min(60000, 15000 * errors));
    });
  }
  document.addEventListener("visibilitychange", function () { if (document.visibilityState === "visible" && key && !over) poll(); });
  var raw = b64u(keyText);
  if (!/^[A-Za-z0-9_-]{22}$/.test(token) || !raw || raw.length !== 32 || !window.crypto || !crypto.subtle) {
    ended(!window.crypto || !crypto.subtle ? "This browser can’t open the trip. Try another browser." : "This link is missing its key. Ask for the link again (all of it, with the part after the #).");
    return;
  }
  crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["decrypt"]).then(function (k) { key = k; poll(); },
    function () { ended("This browser can’t open the trip. Try another browser."); });
})();
`;
