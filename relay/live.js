// Haltewekker live links (0.30): a web page with your trip's live times for someone without the app (a parent).
//
// The phone makes a link   https://<relay>/live/<token>#k=<key>   (0.30 made "#<key>": the page reads both)
//   secret = 32 random bytes (only the phone has it: it lets it write);  key = 32 more random bytes (AES-256-GCM)
//   token  = base64url(first 16 bytes of SHA-256("hw-live-token-v1" + secret))  (22 characters)
// and, on the ride's network tick, posts the trip's state locked with the key:
//   data = 0x01 | nonce (12) | AES-256-GCM ciphertext | tag (16), AAD "hw-live-v1\n" + token
// The key is only in the link's fragment (after the #), which a browser never sends: the relay holds only locked
// bytes it can't read, and forgets everything when the link ends. Nothing here logs a token, a secret or the data.
//
// (relay 2026-11-27) Messages back: whoever has the link (the page, or an app that opened it) can send the sharer a
// short message, locked with the same key (AAD "hw-live-msg-v1\n" + token); the sharer's phone reads them with its
// secret, says which it has seen, and may answer (AAD "hw-live-reply-v1\n" + token), which every page shows. The relay
// only ever holds locked bytes, and drops them all when the link ends.
//
// Routes:
//   POST /live/v1/put  {"secret": b64url(32), "data": b64url(≤ 16 KB), "until": unix s}  -> {"ok":true,"token","exp","mseq"}
//                      the first put makes the link (at most 20 new links an hour per network address, hashed);
//                      it ends at `until`, never later than 4 hours after it was made; a later put may move `until`
//                      within that. Puts at least 5 s apart, at most 240 an hour per link. 410 "ended" once ended.
//                      `mseq`: the newest message's number (0: none), so the phone only asks its inbox when there's one.
//   POST /live/v1/end  {"secret"}                -> {"ok":true}: the data and the messages go at once, the page says it ended
//   GET  /live/v1/get?t=<token>                  -> {"data","at","exp"[,"mseq","seen"][,"replies"]} | 410 {"error":"ended"}
//                                                | 404 {"error":"gone"}   (seen: the newest message the phone has seen)
//   POST /live/v1/msg?t=<token>  {"data": b64url(≤ 2 KB, first byte 1)}  -> {"ok":true,"seq","at"}
//                      only while the link is live; at most 50 a link, one per 10 s and 20 an hour per network address
//                      (hashed) and link: 429 "slow_down" / "full"; 410 "ended", 404 "gone"
//   POST /live/v1/inbox {"secret","after": seq}  -> {"msgs":[{"seq","at","data"}],"mseq","seen"}  (the sharer's phone)
//   POST /live/v1/ack   {"secret","seq"}         -> {"ok":true,"seen"}: seen up to `seq` (the pages say "Seen")
//   POST /live/v1/reply {"secret","data": b64url(≤ 2 KB)} -> {"ok":true,"seq"}: the sharer's answer (the newest 10 kept)
//   GET  /live/<token>                           the page (it reads the key from the fragment and decrypts there;
//                                                a key that worked is kept in that browser for that link until it ends)
//   GET  /live/app.js                            the page's script (same origin; the map's library comes pinned, with
//                                                its hash, from unpkg)
// One Durable Object per link (SQLite-backed, its key-value storage), named "t:<token>"; "ip:<hash>" counts new links.
import { APP_JS } from "./live-app.js";

const MAX_AGE = 4 * 3600;                 // a link lives at most this long after it was made
const MAX_DATA = 16384;                   // one state, decoded (0.30 apps send ≤ 4 KB; the whole trip, v2, more)
const MAX_BODY = 32 * 1024;               // one request
const MIN_GAP = 5;                        // seconds between two puts
const PUTS_PER_HOUR = 240;
const GETS_PER_MIN = 120;                 // per link, all viewers together
const NEW_PER_HOUR_PER_IP = 20;
const MAX_MSG = 2048;                     // one message, decoded
const MAX_MSGS = 50;                      // per link
const MSG_GAP = 10;                       // seconds between two messages from one network address to one link
const MSGS_PER_HOUR = 20;                 // per network address and link
const MAX_REPLIES = 10;                   // kept (the newest)
const REPLY_GAP = 5;
const OWNER_PER_MIN = 60;                 // inbox, ack and reply calls per link
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

async function ipKey(request) {
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  return hex(await crypto.subtle.digest("SHA-256", enc.encode("hw-live-ip-v1:" + ip))).slice(0, 32);
}

async function body(request) {
  if (Number(request.headers.get("Content-Length") || "0") > MAX_BODY) return { error: fail("too_big", 413) };
  const raw = await request.arrayBuffer();
  if (raw.byteLength > MAX_BODY) return { error: fail("too_big", 413) };
  let input;
  try { input = JSON.parse(new TextDecoder().decode(raw)); } catch { return { error: fail("bad_json", 400) }; }
  if (typeof input !== "object" || input === null || Array.isArray(input)) return { error: fail("bad_json", 400) };
  return { input };
}

const sealed = (d, max) => !!d && d.length >= 1 + 12 + 16 && d.length <= max && d[0] === 1;

/// The Worker's part: the shape of a request, then the link's own Durable Object.
export async function live(request, env, url) {
  const path = url.pathname;
  if (path === "/live/app.js") {
    if (request.method !== "GET" && request.method !== "HEAD") return fail("method", 405);
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
  if (path === "/live/v1/msg") {
    if (request.method !== "POST") return fail("method", 405);
    const t = url.searchParams.get("t") || "";
    if (!TOKEN.test(t)) return fail("bad_token", 400);
    if (!env.LIVE) return fail("no_storage", 503);
    const { input, error } = await body(request);
    if (error) return error;
    if (!sealed(b64urlDecode(input.data), MAX_MSG)) return fail("bad_data", 400);
    return link(env, t).fetch("https://do/msg", { method: "POST", body: JSON.stringify({ data: input.data, ip: await ipKey(request) }) });
  }
  const owner = { "/live/v1/put": 1, "/live/v1/end": 1, "/live/v1/inbox": 1, "/live/v1/ack": 1, "/live/v1/reply": 1 };
  if (owner[path]) {
    if (request.method !== "POST") return fail("method", 405);
    if (!env.LIVE) return fail("no_storage", 503);
    const { input, error } = await body(request);
    if (error) return error;
    const secret = b64urlDecode(input.secret);
    if (!secret || secret.length !== 32) return fail("bad_secret", 400);
    const token = await liveToken(secret);
    const stub = link(env, token);
    if (path === "/live/v1/end") return stub.fetch("https://do/end", { method: "POST" });
    if (path === "/live/v1/inbox") {
      const after = Number.isInteger(input.after) ? input.after : 0;
      return stub.fetch("https://do/inbox", { method: "POST", body: JSON.stringify({ after }) });
    }
    if (path === "/live/v1/ack") {
      if (!Number.isInteger(input.seq) || input.seq < 0) return fail("bad_seq", 400);
      return stub.fetch("https://do/ack", { method: "POST", body: JSON.stringify({ seq: input.seq }) });
    }
    if (path === "/live/v1/reply") {
      if (!sealed(b64urlDecode(input.data), MAX_MSG)) return fail("bad_data", 400);
      return stub.fetch("https://do/reply", { method: "POST", body: JSON.stringify({ data: input.data }) });
    }
    if (!sealed(b64urlDecode(input.data), MAX_DATA)) return fail("bad_data", 400);
    if (!Number.isInteger(input.until)) return fail("bad_until", 400);
    const put = JSON.stringify({ token, data: input.data, until: input.until });
    let r = await stub.fetch("https://do/put", { method: "POST", body: put });
    if (r.status === 428) {
      // a new link: counted per network address (hashed, kept an hour)
      const g = await env.LIVE.get(env.LIVE.idFromName("ip:" + await ipKey(request))).fetch("https://do/gate", { method: "POST" });
      if (g.status !== 200) return fail("slow_down", 429);
      r = await stub.fetch("https://do/put", { method: "POST", body: put, headers: { "X-Live-New": "1" } });
    }
    return r;
  }
  const m = path.match(/^\/live\/([A-Za-z0-9_-]{22})\/?$/);
  if (m && (request.method === "GET" || request.method === "HEAD")) return page();
  return fail("not_found", 404);
}

const link = (env, token) => env.LIVE.get(env.LIVE.idFromName("t:" + token));
const msgKey = (seq) => "m:" + String(seq).padStart(6, "0");

/// One live link (named "t:<token>") or one network address's counter of new links ("ip:<hash>").
export class LiveCore {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.store = ctx.storage;
    this.minute = 0;
    this.gets = 0;
    this.ownerMinute = 0;
    this.ownerCalls = 0;
  }

  async fetch(request) {
    try {
      const p = new URL(request.url).pathname;
      if (p === "/put") return await this.put(await request.json(), request.headers.get("X-Live-New") === "1");
      if (p === "/end") return await this.end();
      if (p === "/get") return await this.get();
      if (p === "/gate") return await this.gate();
      if (p === "/msg") return await this.msg(await request.json());
      if (p === "/inbox") return await this.inbox(await request.json());
      if (p === "/ack") return await this.ack(await request.json());
      if (p === "/reply") return await this.reply(await request.json());
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
    return json({ ok: true, token: s.token, exp: s.exp, mseq: s.mseq || 0 });
  }

  async end() {
    const s = await this.slot();
    if (s && !s.ended) {
      // (kept, without the data or the messages, until it would have ended: so the page can say it ended)
      s.ended = now();
      s.data = null;
      s.exp = Math.max(s.created + MAX_AGE, now() + 60);
      await this.dropMessages();
      await this.store.put("s", s);
      await this.store.setAlarm((s.exp + 5) * 1000);
    }
    return json({ ok: true });
  }

  async dropMessages() {
    const keys = [];
    for (const prefix of ["m:", "r:"]) for (const k of (await this.store.list({ prefix })).keys()) keys.push(k);
    keys.push("rp");
    for (let i = 0; i < keys.length; i += 100) await this.store.delete(keys.slice(i, i + 100));
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
    const out = { data: s.data, at: s.at, exp: s.exp };
    if (s.mseq) { out.mseq = s.mseq; out.seen = s.seen || 0; }
    if (s.rseq) out.replies = (await this.store.get("rp")) || [];
    return json(out);
  }

  /// A message to the sharer (locked; from whoever has the link).
  async msg({ data, ip }) {
    const s = await this.slot();
    if (!s) return fail("gone", 404);
    if (s.ended || !s.data) return fail("ended", 410);
    if ((s.mseq || 0) >= MAX_MSGS) return fail("full", 429);
    const t = now();
    const hour = Math.floor(t / 3600);
    const rk = "r:" + String(ip || "unknown").slice(0, 32);
    const r = (await this.store.get(rk)) || { last: 0, hour, n: 0 };
    if (r.hour !== hour) { r.hour = hour; r.n = 0; }
    if (t - r.last < MSG_GAP || r.n >= MSGS_PER_HOUR) return fail("slow_down", 429);
    r.last = t;
    r.n += 1;
    s.mseq = (s.mseq || 0) + 1;
    await this.store.put(msgKey(s.mseq), { seq: s.mseq, at: t, data });
    await this.store.put(rk, r);
    await this.store.put("s", s);
    return json({ ok: true, seq: s.mseq, at: t });
  }

  ownerSlow() {
    const minute = Math.floor(now() / 60);
    if (this.ownerMinute !== minute) { this.ownerMinute = minute; this.ownerCalls = 0; }
    this.ownerCalls += 1;
    return this.ownerCalls > OWNER_PER_MIN;
  }

  async inbox({ after }) {
    const s = await this.slot();
    if (!s) return fail("gone", 404);
    if (s.ended) return fail("ended", 410);
    if (this.ownerSlow()) return fail("slow_down", 429);
    const msgs = [];
    const from = Math.max(0, after | 0);
    if ((s.mseq || 0) > from) {
      for (const [, v] of await this.store.list({ prefix: "m:", start: msgKey(from + 1) })) msgs.push(v);
    }
    return json({ msgs, mseq: s.mseq || 0, seen: s.seen || 0 });
  }

  async ack({ seq }) {
    const s = await this.slot();
    if (!s) return fail("gone", 404);
    if (s.ended) return fail("ended", 410);
    if (this.ownerSlow()) return fail("slow_down", 429);
    const seen = Math.min(seq, s.mseq || 0);
    if (seen > (s.seen || 0)) { s.seen = seen; await this.store.put("s", s); }
    return json({ ok: true, seen: s.seen || 0 });
  }

  async reply({ data }) {
    const s = await this.slot();
    if (!s) return fail("gone", 404);
    if (s.ended || !s.data) return fail("ended", 410);
    if (this.ownerSlow()) return fail("slow_down", 429);
    const t = now();
    if (t - (s.rat || 0) < REPLY_GAP) return fail("slow_down", 429);
    s.rseq = (s.rseq || 0) + 1;
    s.rat = t;
    const list = ((await this.store.get("rp")) || []).concat([{ seq: s.rseq, at: t, data }]).slice(-MAX_REPLIES);
    await this.store.put("rp", list);
    await this.store.put("s", s);
    return json({ ok: true, seq: s.rseq, at: t });
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

// The map: MapLibre GL JS, pinned, with its hash (the browser refuses any other file); OpenFreeMap's dark style (no
// key, no cookies; the tiles see only the relay's name, never the link). Its worker runs from a blob: URL.
const ML = "https://unpkg.com/maplibre-gl@4.7.1/dist/";
const ML_JS_SRI = "sha384-SYKAG6cglRMN0RVvhNeBY0r3FYKNOJtznwA0v7B5Vp9tr31xAHsZC0DqkQ/pZDmj";
const ML_CSS_SRI = "sha384-MinO0mNliZ3vwppuPOUnGa+iq619pfMhLVUXfC4LHwSCvF9H+6P/KO4Q7qBOYV5V";
const TILES = "https://tiles.openfreemap.org";
// (music, when the sharer's app sends what they listen to) album covers only from these
const COVERS = "https://i.scdn.co https://*.mzstatic.com https://lastfm.freetls.fastly.net";

export const CSP = "default-src 'none'; script-src 'self' https://unpkg.com; style-src 'unsafe-inline' https://unpkg.com; " +
  `img-src data: blob: ${TILES} ${COVERS}; connect-src 'self' ${TILES}; worker-src blob:; child-src blob:; ` +
  "base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

function page() {
  return new Response(PAGE, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": CSP,
      // (the map's tiles and its library see only the relay's name, never the link)
      "Referrer-Policy": "strict-origin",
      "X-Content-Type-Options": "nosniff",
      "X-Robots-Tag": "noindex, nofollow",
    },
  });
}

const PAGE = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="strict-origin"><meta name="theme-color" content="#111316"><meta name="color-scheme" content="dark">
<title>Live trip · Haltewekker</title>
<link rel="stylesheet" href="${ML}maplibre-gl.css" integrity="${ML_CSS_SRI}" crossorigin="anonymous">
<style>
:root{--bg:#111316;--card:#1E2126;--card2:#2A2E34;--line:#3A3F47;--text:#F2F4F5;--sub:#A3ABB3;--acc:#3DD598;--yel:#E8A33D;--grey:#6B7280;--warn:#FF8A5C;--col:#E0632E}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.4 -apple-system,system-ui,"Segoe UI",Roboto,sans-serif;-webkit-text-size-adjust:100%;overflow:hidden}
#map{position:fixed;inset:0;background:var(--bg)}
.nomap #map{background:radial-gradient(120% 80% at 50% 20%,#1b1f24,#111316)}
.maplibregl-ctrl-attrib{background:rgba(17,19,22,.7)!important;color:var(--sub)}
.maplibregl-ctrl-attrib a{color:var(--sub)!important}
.maplibregl-ctrl-attrib-button{filter:invert(1)}
.sheet{position:fixed;left:0;right:0;bottom:0;max-height:88vh;height:var(--h,56vh);background:var(--card);border-radius:24px 24px 0 0;
padding:10px 18px calc(18px + env(safe-area-inset-bottom));overflow-y:auto;overscroll-behavior:contain;box-shadow:0 -8px 30px rgba(0,0,0,.35);
transition:height .25s ease;z-index:3;scrollbar-width:none}
.sheet::-webkit-scrollbar{display:none}
.sheet.drag{transition:none}
.grab{display:block;width:100%;height:22px;margin:-10px 0 4px;padding:0;border:0;background:none;cursor:grab;touch-action:none}
.grab::before{content:"";display:block;width:40px;height:5px;border-radius:3px;background:var(--line);margin:9px auto 0}
@media (min-width:900px){.sheet{left:16px;top:16px;bottom:16px;right:auto;width:400px;height:auto!important;max-height:none;border-radius:24px;padding-top:18px}.grab{display:none}}
.who{display:flex;gap:12px;align-items:center}.grow{flex:1;min-width:0}
.age{display:flex;align-items:center;gap:5px;font-size:12px;color:var(--sub);white-space:nowrap;align-self:flex-start;margin-top:22px}
.music{display:flex;gap:12px;align-items:center;background:var(--card2);border-radius:16px;padding:10px 12px;margin-top:14px}
.music p{margin:0}.cover{flex:none;width:44px;height:44px;border-radius:8px;overflow:hidden;display:inline-flex;align-items:center;justify-content:center;
color:#fff;font-size:20px;background:linear-gradient(135deg,#7B5CF0,#E0457B)}.cover img{width:100%;height:100%;object-fit:cover}
.lis{display:flex;align-items:center;gap:6px;font-size:11px;font-weight:800;letter-spacing:.6px;color:var(--acc);text-transform:uppercase}
.eq{display:inline-flex;align-items:flex-end;gap:2px;height:12px}.eq i{width:3px;height:100%;background:var(--acc);border-radius:1px;animation:eq 1s ease-in-out infinite}
.eq i:nth-child(2){animation-delay:-.4s}.eq i:nth-child(3){animation-delay:-.7s}.eq i:nth-child(4){animation-delay:-.2s}
@keyframes eq{0%,100%{transform:scaleY(.35)}50%{transform:scaleY(1)}}.eq i{transform-origin:bottom}
.mt{font-weight:800;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.open{flex:none;font-size:13px;color:var(--text);text-decoration:none;border:1px solid var(--line);border-radius:10px;padding:6px 10px}
.face{flex:none;width:42px;height:42px;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;font-weight:800;font-size:17px;color:#fff;background:#0E7A55}
.eyebrow{margin:0;font-size:13px;font-weight:800;letter-spacing:.8px;color:var(--acc);text-transform:uppercase}
.eyebrow.almost{color:var(--yel)}.eyebrow.grey{color:var(--sub)}.eyebrow.warn{color:var(--warn)}
h1{margin:0;font-size:20px;line-height:1.25;font-weight:800;overflow-wrap:anywhere}
.sub{margin:2px 0 0;font-size:14px;color:var(--sub);overflow-wrap:anywhere}
.big{display:flex;justify-content:space-between;align-items:flex-end;gap:12px;background:var(--card2);border-radius:16px;padding:12px 14px;margin-top:14px}
.big p{margin:0}.small{font-size:12px;color:var(--sub)}
.t1{font-size:32px;font-weight:800;line-height:1.1;font-variant-numeric:tabular-nums}
.t2{font-size:20px;font-weight:800;font-variant-numeric:tabular-nums}
.then{text-align:right}
.note{background:var(--card2);border-radius:16px;padding:12px 14px;margin-top:12px;font-size:15px;overflow-wrap:anywhere}
.legs{display:flex;flex-wrap:wrap;align-items:center;gap:6px;margin-top:14px;font-size:13px;color:var(--sub)}
.chip{display:inline-block;color:#fff;font-weight:800;font-size:12px;border-radius:6px;padding:2px 7px;background:var(--col)}
.chip.done{opacity:.4}.chip.cur{outline:2px solid #fff;outline-offset:1px}
.tl{list-style:none;margin:18px 0 0;padding:0;position:relative}
.tl::before{content:"";position:absolute;left:68px;top:10px;bottom:22px;width:2px;background:var(--line)}
.tl li{display:flex;gap:12px;align-items:flex-start;min-height:52px;position:relative}
.tl .tm{width:50px;flex:none;font-size:13px;font-weight:700;padding-top:1px;font-variant-numeric:tabular-nums}
.tl .pt{flex:none;width:14px;height:14px;border-radius:7px;margin-top:3px;background:var(--bg);border:3px solid var(--grey);position:relative;z-index:1}
.tl .done .pt{background:var(--grey);border-color:var(--grey)}
.tl .now .pt{background:var(--col);border-color:var(--col);animation:pulse 2s ease-in-out infinite}
.tl .ti{font-weight:700;overflow-wrap:anywhere}.tl .su{font-size:12px;color:var(--sub);overflow-wrap:anywhere}
.tl .done .tm,.tl .done .ti{color:var(--sub)}
@keyframes pulse{0%,100%{box-shadow:0 0 0 4px rgba(255,255,255,.12)}50%{box-shadow:0 0 0 9px rgba(255,255,255,.04)}}
.dot{width:8px;height:8px;border-radius:4px;background:var(--acc);flex:none}
.dot.grey{background:var(--grey)}
.msg{margin-top:18px;border-top:1px solid var(--line);padding-top:14px}
.msg h2{margin:0 0 8px;font-size:16px;overflow-wrap:anywhere}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:8px}
.chips button,.send,.pill,.ghost{font:inherit;color:var(--text);background:var(--card2);border:0;border-radius:999px;padding:7px 12px;font-size:14px;cursor:pointer}
input,textarea{display:block;width:100%;font:inherit;font-size:16px;color:var(--text);background:var(--card2);border:1px solid transparent;border-radius:12px;padding:10px 12px;margin:0 0 8px}
input:focus,textarea:focus{outline:none;border-color:var(--acc)}
textarea{resize:none;height:44px;margin:0;min-width:0}
.compose{display:flex;gap:8px;align-items:flex-end;background:var(--card2);border-radius:14px;padding:6px 6px 6px 4px;margin-bottom:8px}
.compose textarea{background:none;border:0;flex:1}
.row{display:flex;align-items:center;justify-content:space-between;gap:8px}
.send{background:var(--acc);color:#0B2A1E;font-weight:800;padding:9px 18px}
.send:disabled{opacity:.5}
.sent{list-style:none;margin:10px 0 0;padding:0}
.sent li{background:var(--card2);border-radius:14px;padding:8px 12px;margin-top:6px;font-size:14px;overflow-wrap:anywhere}
.sent li.them{background:#16352A}
.sent .small{display:block;margin-top:2px}
.pill{position:fixed;top:calc(12px + env(safe-area-inset-top));right:12px;z-index:4;background:rgba(30,33,38,.92);text-decoration:none;font-weight:700}
.ghost{position:fixed;right:12px;z-index:2;bottom:calc(var(--h,56vh) + 12px);width:40px;height:40px;padding:0;font-size:20px;background:rgba(30,33,38,.92)}
@media (min-width:900px){.ghost{bottom:24px}}
.mk{display:flex;align-items:center;justify-content:center;min-width:44px;height:30px;padding:0 8px;border-radius:9px;border:2.5px solid #fff;
color:#fff;font-weight:800;font-size:13px;background:var(--col);box-shadow:0 0 0 10px rgba(255,255,255,.08)}
.mk.old{filter:grayscale(1);opacity:.7}
.dest{width:22px;height:22px;border-radius:50%;background:var(--acc);border:3px solid var(--bg)}
.lbl{position:absolute;bottom:28px;left:50%;transform:translateX(-50%);font-size:11px;font-weight:700;color:var(--text);text-shadow:0 1px 3px #000;white-space:nowrap}
.foot{font-size:12px;color:var(--sub);margin:16px 0 0}
[hidden]{display:none!important}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style></head><body>
<div id="map" aria-hidden="true"></div>
<a id="openApp" class="pill" hidden>Open in Haltewekker</a>
<button id="recentre" class="ghost" type="button" aria-label="Show the whole ride" hidden>⌖</button>
<main id="card" class="sheet" aria-live="polite">
<button id="grab" class="grab" type="button" aria-label="Show more or less"></button>
<div class="who"><span id="face" class="face" aria-hidden="true">·</span><div class="grow">
<p id="eyebrow" class="eyebrow">Live trip</p><h1 id="head">Opening the trip…</h1><p id="sub" class="sub" hidden></p></div>
<span id="age" class="age" hidden><span id="ageDot" class="dot"></span><span id="ageText"></span></span></div>
<div id="music" class="music" hidden><span id="cover" class="cover" aria-hidden="true">♪</span><div class="grow">
<p class="lis"><span class="eq" aria-hidden="true"><i></i><i></i><i></i><i></i></span>Listening now</p>
<p id="muTitle" class="mt"></p><p id="muSub" class="small"></p></div>
<a id="muOpen" class="open" target="_blank" rel="noopener noreferrer" hidden>Open ↗</a></div>
<div id="big" class="big" hidden><div><p id="bigPlace" class="small"></p><p id="bigTime" class="t1"></p><p id="bigSub" class="small"></p></div>
<div id="then" class="then" hidden><p id="thenPlace" class="small"></p><p id="thenTime" class="t2"></p></div></div>
<div id="note" class="note" hidden></div>
<div id="legs" class="legs" hidden></div>
<ol id="tl" class="tl" hidden></ol>
<section id="msg" class="msg" hidden>
<h2 id="msgHead">Send a message</h2>
<p id="msgNote" class="small" hidden></p>
<div id="chips" class="chips"></div>
<div class="compose"><textarea id="msgText" maxlength="280" rows="1" placeholder="Send a message…" aria-label="Your message"></textarea>
<button id="msgSend" class="send" type="button">Send</button></div>
<input id="msgName" maxlength="40" autocomplete="nickname" placeholder="Your name (optional)" aria-label="Your name (optional)">
<p id="msgInfo" class="small" hidden></p>
<ul id="sent" class="sent"></ul>
</section>
<noscript><p class="sub">Turn on JavaScript to see the trip.</p></noscript>
<p class="foot">Only people with this link can see this trip. It ends when the trip does (at most 4 hours). The trip and the
messages are locked with a key that is only in the link (after the #), so the relay that passes them on can’t read them.
Made with Haltewekker.</p>
</main>
<script src="${ML}maplibre-gl.js" integrity="${ML_JS_SRI}" crossorigin="anonymous" defer></script>
<script src="/live/app.js" defer></script></body></html>`;
