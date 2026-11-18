// Haltewekker Friends relay (0.25): end-to-end encrypted mailboxes on Durable Objects (SQLite storage).
//
// The relay never sees what is in a box: every box is locked on the phone for one friend (see the app's FriendBox).
// It only knows account ids, each account's public signing key, which account left a box for which, when, and how
// big. Nothing here logs a box, a key or a body.
//
// Accounts: the id is the first 16 bytes of SHA-256("haltewekker-account-v1" + signing public key), in hex, so an id
// can't be claimed with another key. Every request but /f/v1/status is signed by the account's Ed25519 key:
//   X-HW-Account: id (32 hex)       X-HW-Device: this phone's random id (32 hex)
//   X-HW-Time: unix seconds          X-HW-Nonce: 16-64 random characters [A-Za-z0-9_-], never used twice
//   X-HW-Signature: base64url Ed25519 signature over
//   "HW1\n" + method + "\n" + path + "\n" + account + "\n" + device + "\n" + time + "\n" + nonce + "\n" + hex(SHA-256(body))
// One phone at a time: /f/v1/register from another device moves the account there, and the old phone's next request
// gets 409 {"error":"signed_out"}.
//
// Routes (POST, JSON in and out):
//   /f/v1/status            (GET, unsigned) {"ok":true,"v":1}
//   /f/v1/register          {"signKey": b64url}                      -> {"account","created","moved"}
//   /f/v1/send              {"boxes":[{"to","data","slot"?,"ttl"?}]}  -> {"results":[{"to","ok","id"?,"error"?}]}
//                           a box with a slot replaces the sender's earlier box in that slot (latest state, 0.26+)
//   /f/v1/inbox             {"after"?: id, "limit"?}                 -> {"boxes":[{"id","from","slot","at","exp","data"}],"cursor","more"}
//   /f/v1/ack               {"ids":[id]}                              -> {"deleted"}
//   /f/v1/drop              {"peer"}                                  -> boxes between you and peer deleted, both ways
//   /f/v1/block             {"peer","on"}                             -> boxes from peer refused (quietly) while on
//   /f/v1/vault/put         {"data": b64url}                          -> your own locked backup (the friend list)
//   /f/v1/vault/get         {}                                        -> {"data"|null,"at"}
//   /f/v1/leave             {}                                        -> the account and all its boxes deleted
//   /add                    (GET) a small page for share links: https://<relay>/add#<the link's fields>

const V = 1;
const SKEW = 300;                         // seconds a request's clock may be off
const MAX_BODY = 1024 * 1024;             // one request
const MAX_BOX = 64 * 1024;                // one box (decoded)
const MAX_VAULT = 128 * 1024;
const MAX_SEND = 20;                      // boxes per send request
const MAX_TTL = 30 * 86400;
const MIN_TTL = 60;
const INBOX_MAX_BOXES = 1000;
const INBOX_MAX_BYTES = 8 * 1024 * 1024;
const PER_SENDER_MAX = 200;               // boxes one sender may have waiting in one inbox
const REQS_PER_MIN = 60;
const BOXES_PER_HOUR = 600;
const REGISTERS_PER_HOUR_PER_IP = 20;
const IDLE_DELETE = 400 * 86400;          // an account nobody used for this long is deleted

const HEX32 = /^[0-9a-f]{32}$/;
const SLOT = /^[a-z0-9._-]{1,32}$/;
const B64URL = /^[A-Za-z0-9_-]*={0,2}$/;

const json = (o, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
const fail = (error, status) => json({ error }, status);

function b64urlDecode(s) {
  if (typeof s !== "string" || !B64URL.test(s)) return null;
  const t = s.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  const pad = t + "===".slice((t.length + 3) % 4);
  try {
    const bin = atob(pad);
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
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const sha256 = (bytes) => crypto.subtle.digest("SHA-256", bytes);
const enc = new TextEncoder();

export async function accountIdFor(signKey) {
  const pre = enc.encode("haltewekker-account-v1");
  const all = new Uint8Array(pre.length + signKey.length);
  all.set(pre, 0); all.set(signKey, pre.length);
  return hex(await sha256(all)).slice(0, 32);
}

async function ed25519Verify(keyBytes, sig, data) {
  let key;
  try {
    key = await crypto.subtle.importKey("raw", keyBytes, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, sig, data);
  } catch {
    // older runtimes named it NODE-ED25519
    try {
      key = await crypto.subtle.importKey("raw", keyBytes, { name: "NODE-ED25519", namedCurve: "NODE-ED25519" }, false, ["verify"]);
      return await crypto.subtle.verify({ name: "NODE-ED25519" }, key, sig, data);
    } catch { return false; }
  }
}

export function canonical(method, path, account, device, time, nonce, bodyHashHex) {
  return `HW1\n${method}\n${path}\n${account}\n${device}\n${time}\n${nonce}\n${bodyHashHex}`;
}

const PUBLIC = new Set(["/f/v1/register", "/f/v1/send", "/f/v1/inbox", "/f/v1/ack", "/f/v1/drop", "/f/v1/block",
  "/f/v1/vault/put", "/f/v1/vault/get", "/f/v1/leave"]);

/// The Worker's part: checks the shape of a request and hands it to the account's Durable Object.
export async function friends(request, env, url) {
  const path = url.pathname;
  if (path === "/add") return addPage();
  if (path === "/f/v1/status") return json({ ok: true, v: V, storage: !!env.FRIENDS });
  if (!PUBLIC.has(path)) return fail("not_found", 404);
  if (request.method !== "POST") return fail("method", 405);
  if (!env.FRIENDS) return fail("no_storage", 503);
  const len = Number(request.headers.get("Content-Length") || "0");
  if (len > MAX_BODY) return fail("too_big", 413);
  const account = (request.headers.get("X-HW-Account") || "").toLowerCase();
  if (!HEX32.test(account)) return fail("bad_account", 400);
  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_BODY) return fail("too_big", 413);
  if (path === "/f/v1/register") {
    // a cheap guard against making accounts in bulk: per network address, hashed, kept an hour
    const ip = request.headers.get("CF-Connecting-IP") || "unknown";
    const ipKey = hex(await sha256(enc.encode("hw-ip-v1:" + ip))).slice(0, 32);
    const gate = env.FRIENDS.get(env.FRIENDS.idFromName("ip:" + ipKey));
    const g = await gate.fetch("https://do/int/gate", { method: "POST" });
    if (g.status !== 200) return fail("slow_down", 429);
  }
  const stub = env.FRIENDS.get(env.FRIENDS.idFromName("a:" + account));
  const headers = new Headers();
  for (const h of ["X-HW-Account", "X-HW-Device", "X-HW-Time", "X-HW-Nonce", "X-HW-Signature"]) {
    const v = request.headers.get(h);
    if (v) headers.set(h, v);
  }
  headers.set("X-HW-Path", path);
  return stub.fetch("https://do/pub", { method: "POST", headers, body });
}

/// One account's mailbox (or, named "ip:…", one network address's register counter).
export class FriendsCore {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.sql = ctx.storage.sql;
    this.schema();
  }

  schema() {
    this.sql.exec(`CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS boxes (id INTEGER PRIMARY KEY AUTOINCREMENT, sender TEXT NOT NULL,
      slot TEXT, at INTEGER NOT NULL, exp INTEGER NOT NULL, size INTEGER NOT NULL, data TEXT NOT NULL)`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS boxes_exp ON boxes (exp)`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS boxes_sender ON boxes (sender, slot)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS seen (sig TEXT PRIMARY KEY, exp INTEGER NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS rate (bucket TEXT PRIMARY KEY, n INTEGER NOT NULL, exp INTEGER NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS blocked (peer TEXT PRIMARY KEY)`);
  }

  now() { return Math.floor(Date.now() / 1000); }
  get(k) { const r = this.sql.exec(`SELECT v FROM meta WHERE k = ?`, k).toArray(); return r.length ? r[0].v : null; }
  put(k, v) { this.sql.exec(`INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v`, k, String(v)); }

  /// Counts one more in this bucket; false once it passes the limit.
  bump(bucket, limit, life, by = 1) {
    const now = this.now();
    this.sql.exec(`DELETE FROM rate WHERE exp < ?`, now);
    const r = this.sql.exec(`SELECT n FROM rate WHERE bucket = ?`, bucket).toArray();
    const n = (r.length ? r[0].n : 0) + by;
    if (n > limit) return false;
    this.sql.exec(`INSERT INTO rate (bucket, n, exp) VALUES (?, ?, ?) ON CONFLICT(bucket) DO UPDATE SET n = excluded.n`, bucket, n, now + life);
    return true;
  }

  async fetch(request) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/int/gate") {
        const ok = this.bump("reg:" + Math.floor(this.now() / 3600), REGISTERS_PER_HOUR_PER_IP, 3600);
        await this.wake(this.now() + 3700);
        return ok ? json({ ok: true }) : fail("slow_down", 429);
      }
      if (url.pathname === "/int/deposit") return await this.deposit(await request.json());
      if (url.pathname === "/int/drop") return this.dropFrom((await request.json()).peer);
      if (url.pathname === "/pub") return await this.pub(request);
      return fail("not_found", 404);
    } catch (e) {
      return fail("relay_error", 500);
    }
  }

  async pub(request) {
    const path = request.headers.get("X-HW-Path");
    const account = request.headers.get("X-HW-Account");
    const device = (request.headers.get("X-HW-Device") || "").toLowerCase();
    const time = request.headers.get("X-HW-Time") || "";
    const nonce = request.headers.get("X-HW-Nonce") || "";
    const sig = b64urlDecode(request.headers.get("X-HW-Signature") || "");
    const body = new Uint8Array(await request.arrayBuffer());
    if (!HEX32.test(device)) return fail("bad_device", 400);
    if (!/^\d{9,11}$/.test(time) || Math.abs(this.now() - Number(time)) > SKEW) return fail("clock", 401);
    if (!sig || sig.length !== 64) return fail("bad_signature", 401);
    if (!/^[A-Za-z0-9_-]{16,64}$/.test(nonce)) return fail("bad_nonce", 400);
    let input;
    try { input = body.length ? JSON.parse(new TextDecoder().decode(body)) : {}; } catch { return fail("bad_json", 400); }
    if (typeof input !== "object" || input === null || Array.isArray(input)) return fail("bad_json", 400);

    const registered = this.get("signKey");
    let keyBytes;
    if (path === "/f/v1/register") {
      keyBytes = b64urlDecode(input.signKey);
      if (!keyBytes || keyBytes.length !== 32) return fail("bad_key", 400);
      if ((await accountIdFor(keyBytes)) !== account) return fail("wrong_account", 400);
      if (registered && registered !== b64urlEncode(keyBytes)) return fail("wrong_account", 400);
    } else {
      if (!registered) return fail("unknown_account", 404);
      keyBytes = b64urlDecode(registered);
    }
    const msg = enc.encode(canonical("POST", path, account, device, time, nonce, hex(await sha256(body))));
    if (!(await ed25519Verify(keyBytes, sig, msg))) return fail("bad_signature", 401);
    this.sql.exec(`DELETE FROM seen WHERE exp < ?`, this.now());
    if (this.sql.exec(`SELECT 1 FROM seen WHERE sig = ?`, nonce).toArray().length) return fail("replay", 401);
    this.sql.exec(`INSERT INTO seen (sig, exp) VALUES (?, ?)`, nonce, Number(time) + SKEW + 60);

    if (path === "/f/v1/register") return this.register(account, b64urlEncode(keyBytes), device);
    if (this.get("device") !== device) return fail("signed_out", 409);
    if (!this.bump("req:" + Math.floor(this.now() / 60), REQS_PER_MIN, 120)) return fail("slow_down", 429);
    this.put("lastSeen", this.now());
    switch (path) {
      case "/f/v1/send": return await this.send(account, input);
      case "/f/v1/inbox": return this.inbox(input);
      case "/f/v1/ack": return this.ack(input);
      case "/f/v1/drop": return await this.drop(account, input);
      case "/f/v1/block": return this.block(input);
      case "/f/v1/vault/put": return this.vaultPut(input);
      case "/f/v1/vault/get": return this.vaultGet();
      case "/f/v1/leave": return await this.leave();
    }
    return fail("not_found", 404);
  }

  async register(account, key, device) {
    const was = this.get("device");
    const created = !this.get("signKey");
    this.put("signKey", key);
    this.put("account", account);
    this.put("device", device);
    this.put("lastSeen", this.now());
    if (created) this.put("created", this.now());
    await this.wake(this.now() + IDLE_DELETE);
    return json({ account, created, moved: !!was && was !== device });
  }

  async send(account, input) {
    const list = input.boxes;
    if (!Array.isArray(list) || list.length === 0 || list.length > MAX_SEND) return fail("bad_boxes", 400);
    if (!this.bump("box:" + Math.floor(this.now() / 3600), BOXES_PER_HOUR, 3700, list.length)) return fail("slow_down", 429);
    const results = [];
    for (const b of list) {
      const to = typeof b?.to === "string" ? b.to.toLowerCase() : "";
      const raw = b64urlDecode(b?.data);
      const slot = b?.slot ?? null;
      const ttl = b?.ttl ?? MAX_TTL;
      if (!HEX32.test(to) || to === account) { results.push({ to, ok: false, error: "bad_to" }); continue; }
      if (!raw || raw.length === 0 || raw.length > MAX_BOX) { results.push({ to, ok: false, error: "bad_data" }); continue; }
      if (slot !== null && (typeof slot !== "string" || !SLOT.test(slot))) { results.push({ to, ok: false, error: "bad_slot" }); continue; }
      if (!Number.isInteger(ttl) || ttl < MIN_TTL || ttl > MAX_TTL) { results.push({ to, ok: false, error: "bad_ttl" }); continue; }
      const stub = this.env.FRIENDS.get(this.env.FRIENDS.idFromName("a:" + to));
      const r = await stub.fetch("https://do/int/deposit", {
        method: "POST",
        body: JSON.stringify({ from: account, slot, ttl, data: b.data, size: raw.length }),
      });
      const out = await r.json().catch(() => ({}));
      results.push(r.status === 200 ? { to, ok: true, id: out.id } : { to, ok: false, error: out.error || "relay_error" });
    }
    return json({ results });
  }

  async deposit({ from, slot, ttl, data, size }) {
    if (!this.get("signKey")) return fail("unknown_account", 404);
    const now = this.now();
    this.sql.exec(`DELETE FROM boxes WHERE exp < ?`, now);
    // refused quietly: the sender can't tell a block from a delivery
    if (this.sql.exec(`SELECT 1 FROM blocked WHERE peer = ?`, from).toArray().length) return json({ id: 0 });
    if (slot !== null) this.sql.exec(`DELETE FROM boxes WHERE sender = ? AND slot = ?`, from, slot);
    const tot = this.sql.exec(`SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS s FROM boxes`).toArray()[0];
    if (tot.n >= INBOX_MAX_BOXES || tot.s + size > INBOX_MAX_BYTES) return fail("inbox_full", 507);
    const mine = this.sql.exec(`SELECT COUNT(*) AS n FROM boxes WHERE sender = ?`, from).toArray()[0];
    if (mine.n >= PER_SENDER_MAX) return fail("inbox_full", 507);
    const exp = now + ttl;
    this.sql.exec(`INSERT INTO boxes (sender, slot, at, exp, size, data) VALUES (?, ?, ?, ?, ?, ?)`, from, slot, now, exp, size, data);
    const id = this.sql.exec(`SELECT last_insert_rowid() AS id`).toArray()[0].id;
    await this.wake(exp + 5);
    return json({ id });
  }

  inbox(input) {
    const after = Number.isInteger(input.after) && input.after >= 0 ? input.after : 0;
    const limit = Number.isInteger(input.limit) ? Math.min(Math.max(input.limit, 1), 100) : 100;
    const now = this.now();
    this.sql.exec(`DELETE FROM boxes WHERE exp < ?`, now);
    const rows = this.sql.exec(`SELECT id, sender, slot, at, exp, size, data FROM boxes WHERE id > ? ORDER BY id LIMIT ?`, after, limit + 1).toArray();
    const boxes = [];
    let bytes = 0;
    for (const r of rows.slice(0, limit)) {
      if (boxes.length && bytes + r.size > 2 * 1024 * 1024) break;
      bytes += r.size;
      boxes.push({ id: r.id, from: r.sender, slot: r.slot, at: r.at, exp: r.exp, data: r.data });
    }
    const cursor = boxes.length ? boxes[boxes.length - 1].id : after;
    return json({ boxes, cursor, more: rows.length > boxes.length });
  }

  ack(input) {
    const ids = input.ids;
    if (!Array.isArray(ids) || ids.length > 500 || !ids.every((i) => Number.isInteger(i) && i > 0)) return fail("bad_ids", 400);
    let n = 0;
    for (const id of ids) n += this.sql.exec(`DELETE FROM boxes WHERE id = ?`, id).rowsWritten || 0;
    return json({ deleted: n });
  }

  dropFrom(peer) {
    if (!HEX32.test(peer || "")) return fail("bad_peer", 400);
    this.sql.exec(`DELETE FROM boxes WHERE sender = ?`, peer);
    return json({ ok: true });
  }

  async drop(account, input) {
    const peer = typeof input.peer === "string" ? input.peer.toLowerCase() : "";
    if (!HEX32.test(peer) || peer === account) return fail("bad_peer", 400);
    this.dropFrom(peer);
    const stub = this.env.FRIENDS.get(this.env.FRIENDS.idFromName("a:" + peer));
    await stub.fetch("https://do/int/drop", { method: "POST", body: JSON.stringify({ peer: account }) });
    return json({ ok: true });
  }

  block(input) {
    const peer = typeof input.peer === "string" ? input.peer.toLowerCase() : "";
    if (!HEX32.test(peer)) return fail("bad_peer", 400);
    if (input.on === false) this.sql.exec(`DELETE FROM blocked WHERE peer = ?`, peer);
    else {
      if (this.sql.exec(`SELECT COUNT(*) AS n FROM blocked`).toArray()[0].n >= 1000) return fail("too_many", 400);
      this.sql.exec(`INSERT OR IGNORE INTO blocked (peer) VALUES (?)`, peer);
      this.dropFrom(peer);
    }
    return json({ ok: true });
  }

  vaultPut(input) {
    const raw = b64urlDecode(input.data);
    if (!raw || raw.length === 0 || raw.length > MAX_VAULT) return fail("bad_data", 400);
    this.put("vault", input.data);
    this.put("vaultAt", this.now());
    return json({ ok: true, at: this.now() });
  }

  vaultGet() {
    const data = this.get("vault");
    return json({ data, at: data ? Number(this.get("vaultAt")) : null });
  }

  async leave() {
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    this.schema();
    return json({ ok: true });
  }

  /// Makes sure an alarm comes by `at` at the latest (expired boxes go, an idle account goes).
  async wake(at) {
    const cur = await this.ctx.storage.getAlarm();
    if (cur === null || cur > at * 1000) await this.ctx.storage.setAlarm(at * 1000);
  }

  async alarm() {
    const now = this.now();
    this.sql.exec(`DELETE FROM boxes WHERE exp < ?`, now);
    this.sql.exec(`DELETE FROM seen WHERE exp < ?`, now);
    this.sql.exec(`DELETE FROM rate WHERE exp < ?`, now);
    const key = this.get("signKey");
    const seen = Number(this.get("lastSeen") || "0");
    if (!key) {
      // a register counter (or nothing): gone once its counts are
      if (this.sql.exec(`SELECT COUNT(*) AS n FROM rate`).toArray()[0].n === 0) { await this.ctx.storage.deleteAll(); return; }
      await this.ctx.storage.setAlarm((now + 3700) * 1000);
      return;
    }
    if (now - seen > IDLE_DELETE) { await this.ctx.storage.deleteAll(); return; }
    const next = this.sql.exec(`SELECT MIN(exp) AS e FROM boxes`).toArray()[0].e;
    const at = Math.min(next ? next + 5 : Infinity, seen + IDLE_DELETE + 60);
    await this.ctx.storage.setAlarm(at * 1000);
  }
}

function addPage() {
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Add a friend · Haltewekker</title>
<style>
:root{color-scheme:light dark;--bg:#F1F3F5;--card:#fff;--text:#14171A;--sub:#5B636B;--accent:#0E7A55}
@media (prefers-color-scheme:dark){:root{--bg:#111417;--card:#1C1F23;--text:#ECEEF0;--sub:#A3ABB3}}
body{margin:0;background:var(--bg);color:var(--text);font:17px/1.45 -apple-system,system-ui,sans-serif}
main{max-width:420px;margin:0 auto;padding:40px 16px}
.card{background:var(--card);border-radius:24px;padding:24px}
h1{font-size:24px;margin:0 0 8px}p{color:var(--sub);margin:0 0 16px}
a.btn{display:block;text-align:center;background:var(--accent);color:#fff;text-decoration:none;font-weight:600;
padding:16px;border-radius:999px;margin:20px 0 12px}
</style></head><body><main><div class="card">
<h1 id="t">Add a friend</h1>
<p>Someone sent you their Haltewekker friend code. Open it in the app to send them a friend request.</p>
<a class="btn" id="open" href="haltewekker://friend">Open in Haltewekker</a>
<p>Don’t have Haltewekker yet? Ask your friend how they installed it, then open this link again.</p>
<p style="font-size:13px">This page doesn’t send the code anywhere: it stays in the link, after the #.</p>
</div></main><script>
var h = location.hash.slice(1);
if (/^[A-Za-z0-9_\\-=&%.~+]{1,600}$/.test(h)) {
  document.getElementById("open").href = "haltewekker://friend?" + h;
  try { var n = new URLSearchParams(h).get("n"); if (n) document.getElementById("t").textContent = "Add " + n.slice(0, 40) + " as a friend"; } catch (e) {}
}
</script></body></html>`;
  return new Response(html, { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "max-age=3600" } });
}
