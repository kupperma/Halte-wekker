// A local check of the Friends relay (friends.js) without Cloudflare: Durable Objects faked with node:sqlite.
// Run: node relay/test-friends.mjs            (Node 22.13+)
// Or against the live relay (makes and then deletes two throwaway accounts):
//      node relay/test-friends.mjs https://haltewekker-relay.tsfaw1.workers.dev
import { DatabaseSync } from "node:sqlite";
import assert from "node:assert/strict";
import { friends, FriendsCore, accountIdFor, canonical } from "./friends.js";

const LIVE = process.argv[2] || null;

// MARK: a fake Durable Object namespace

class FakeStorage {
  constructor() { this.db = new DatabaseSync(":memory:"); this.alarmAt = null; this.sql = this.makeSql(); }
  makeSql() {
    const db = () => this.db;
    return {
      exec(q, ...binds) {
        const st = db().prepare(q);
        if (/^\s*SELECT/i.test(q)) { const rows = st.all(...binds); return { toArray: () => rows, one: () => rows[0], rowsWritten: 0 }; }
        const r = st.run(...binds);
        return { toArray: () => [], one: () => undefined, rowsWritten: Number(r.changes) };
      },
    };
  }
  async getAlarm() { return this.alarmAt; }
  async setAlarm(t) { this.alarmAt = t; }
  async deleteAlarm() { this.alarmAt = null; }
  async deleteAll() { this.db.close(); this.db = new DatabaseSync(":memory:"); }
}

class FakeNamespace {
  constructor() { this.objects = new Map(); }
  idFromName(n) { return n; }
  get(id) {
    const ns = this;
    return {
      async fetch(url, init) {
        if (!ns.objects.has(id)) ns.objects.set(id, new FriendsCore({ storage: new FakeStorage() }, ns.env));
        const req = url instanceof Request ? url : new Request(url, init);
        return ns.objects.get(id).fetch(req);
      },
    };
  }
}

// MARK: a client, as the app does it

const b64url = (b) => Buffer.from(b).toString("base64url");
const hex = (b) => Buffer.from(b).toString("hex");
async function makeAccount() {
  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey));
  const id = await accountIdFor(pub);
  return { kp, pub, id, device: hex(crypto.getRandomValues(new Uint8Array(16))) };
}

let call;
function setup() {
  if (LIVE) {
    call = (path, init) => fetch(LIVE + path, init);
    return;
  }
  const ns = new FakeNamespace();
  const env = { FRIENDS: ns };
  ns.env = env;
  call = (path, init) => friends(new Request("https://relay.test" + path, init), env, new URL("https://relay.test" + path));
}

async function signed(acct, path, obj, { time, device, sigOverride, nonce } = {}) {
  const body = new TextEncoder().encode(JSON.stringify(obj ?? {}));
  const t = String(time ?? Math.floor(Date.now() / 1000));
  const dev = device ?? acct.device;
  const bh = hex(await crypto.subtle.digest("SHA-256", body));
  const n = nonce ?? b64url(crypto.getRandomValues(new Uint8Array(16)));
  const msg = new TextEncoder().encode(canonical("POST", path, acct.id, dev, t, n, bh));
  const sig = sigOverride ?? new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, acct.kp.privateKey, msg));
  const headers = { "Content-Type": "application/json", "X-HW-Account": acct.id, "X-HW-Device": dev, "X-HW-Time": t, "X-HW-Nonce": n, "X-HW-Signature": b64url(sig) };
  const r = await call(path, { method: "POST", headers, body });
  let j = null;
  try { j = await r.json(); } catch {}
  return { status: r.status, json: j, sig, nonce: n };
}

// MARK: the checks

async function run() {
  setup();
  const st = await call("/f/v1/status", { method: "GET" });
  assert.equal(st.status, 200);
  const sj = await st.json();
  assert.equal(sj.ok, true);
  if (!LIVE) assert.equal(sj.storage, true);
  console.log("status ok", JSON.stringify(sj));

  const page = await call("/add", { method: "GET" });
  assert.equal(page.status, 200);
  assert.match(await page.text(), /Open in Haltewekker/);

  const a = await makeAccount(), b = await makeAccount();
  // not registered yet
  let r = await signed(a, "/f/v1/inbox", {});
  assert.equal(r.status, 404, "inbox before register");
  // register with someone else's key: refused
  r = await signed(a, "/f/v1/register", { signKey: b64url(b.pub) });
  assert.equal(r.status, 400);
  r = await signed(a, "/f/v1/register", { signKey: b64url(a.pub) });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.created, true);
  r = await signed(b, "/f/v1/register", { signKey: b64url(b.pub) });
  assert.equal(r.status, 200);
  console.log("register ok");

  // bad signature, old clock, replay
  r = await signed(a, "/f/v1/inbox", {}, { sigOverride: new Uint8Array(64) });
  assert.equal(r.status, 401);
  r = await signed(a, "/f/v1/inbox", {}, { time: Math.floor(Date.now() / 1000) - 1000 });
  assert.equal(r.status, 401);
  assert.equal(r.json.error, "clock");
  const T = Math.floor(Date.now() / 1000);
  const first = await signed(a, "/f/v1/inbox", {}, { time: T });
  assert.equal(first.status, 200);
  assert.deepEqual(first.json.boxes, []);
  r = await signed(a, "/f/v1/inbox", {}, { sigOverride: first.sig, time: T, nonce: first.nonce });
  assert.equal(r.status, 401);
  assert.equal(r.json.error, "replay");
  console.log("auth ok");

  // send a box to b, and one in a slot (replaced by the next)
  const data = b64url(new TextEncoder().encode("locked box bytes"));
  r = await signed(a, "/f/v1/send", { boxes: [{ to: b.id, data }, { to: b.id, data, slot: "travel", ttl: 600 }] });
  assert.equal(r.status, 200);
  assert.ok(r.json.results.every((x) => x.ok), JSON.stringify(r.json));
  r = await signed(a, "/f/v1/send", { boxes: [{ to: b.id, data: b64url(new TextEncoder().encode("newer")), slot: "travel", ttl: 600 }] });
  assert.ok(r.json.results[0].ok);
  // to nobody
  r = await signed(a, "/f/v1/send", { boxes: [{ to: "0".repeat(32), data }] });
  assert.equal(r.json.results[0].ok, false);
  assert.equal(r.json.results[0].error, "unknown_account");
  // too big
  r = await signed(a, "/f/v1/send", { boxes: [{ to: b.id, data: b64url(new Uint8Array(70000)) }] });
  assert.equal(r.json.results[0].error, "bad_data");
  r = await signed(b, "/f/v1/inbox", { after: 0 });
  assert.equal(r.status, 200);
  assert.equal(r.json.boxes.length, 2, JSON.stringify(r.json));
  assert.equal(r.json.boxes[0].from, a.id);
  assert.equal(r.json.boxes[0].slot, null);
  assert.equal(r.json.boxes[1].slot, "travel");
  assert.equal(Buffer.from(r.json.boxes[1].data, "base64url").toString(), "newer");
  const cursor = r.json.cursor;
  r = await signed(b, "/f/v1/inbox", { after: cursor });
  assert.equal(r.json.boxes.length, 0);
  // ack the mail box
  const all = (await signed(b, "/f/v1/inbox", {})).json.boxes;
  r = await signed(b, "/f/v1/ack", { ids: [all[0].id] });
  assert.equal(r.status, 200);
  assert.equal((await signed(b, "/f/v1/inbox", {})).json.boxes.length, 1);
  console.log("send/inbox/ack ok");

  // drop: both ways
  await signed(b, "/f/v1/send", { boxes: [{ to: a.id, data }] });
  r = await signed(a, "/f/v1/drop", { peer: b.id });
  assert.equal(r.status, 200);
  assert.equal((await signed(b, "/f/v1/inbox", {})).json.boxes.length, 0);
  assert.equal((await signed(a, "/f/v1/inbox", {})).json.boxes.length, 0);
  // block: quietly refused
  await signed(b, "/f/v1/block", { peer: a.id, on: true });
  r = await signed(a, "/f/v1/send", { boxes: [{ to: b.id, data }] });
  assert.equal(r.json.results[0].ok, true);
  assert.equal((await signed(b, "/f/v1/inbox", {})).json.boxes.length, 0);
  await signed(b, "/f/v1/block", { peer: a.id, on: false });
  r = await signed(a, "/f/v1/send", { boxes: [{ to: b.id, data }] });
  assert.equal((await signed(b, "/f/v1/inbox", {})).json.boxes.length, 1);
  console.log("drop/block ok");

  // latest states (0.26): put replaces, get doesn't delete, clear takes it back, block refuses quietly
  r = await signed(b, "/f/v1/state/get", {});
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.deepEqual(r.json.states, []);
  const mailBefore = (await signed(b, "/f/v1/inbox", {})).json.boxes.length;
  const s1 = b64url(new TextEncoder().encode("state one")), s2 = b64url(new TextEncoder().encode("state two"));
  r = await signed(a, "/f/v1/state/put", { states: [{ to: b.id, data: s1, ttl: 120 }] });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.results[0].ok, true, JSON.stringify(r.json));
  r = await signed(a, "/f/v1/state/put", { states: [{ to: b.id, data: s2 }, { to: "0".repeat(32), data: s2 }, { to: b.id, data: s1, ttl: 5 }] });
  assert.equal(r.json.results[0].ok, true);
  assert.equal(r.json.results[1].error, "unknown_account");
  assert.equal(r.json.results[2].error, "bad_to");          // (the same friend twice in one put)
  r = await signed(a, "/f/v1/state/put", { states: [{ to: b.id, data: b64url(new Uint8Array(17000)) }] });
  assert.equal(r.json.results[0].error, "bad_data");
  r = await signed(a, "/f/v1/state/put", { states: [{ to: b.id, data: s2, ttl: 5000 }] });
  assert.equal(r.json.results[0].error, "bad_ttl");
  r = await signed(b, "/f/v1/state/get", {});
  assert.equal(r.json.states.length, 1, JSON.stringify(r.json));
  assert.equal(r.json.states[0].from, a.id);
  assert.equal(r.json.states[0].data, s2);
  assert.ok(r.json.states[0].exp - r.json.states[0].at <= 300 && r.json.states[0].exp > r.json.states[0].at);
  assert.equal((await signed(b, "/f/v1/state/get", {})).json.states.length, 1, "a read doesn't delete it");
  assert.equal((await signed(b, "/f/v1/inbox", {})).json.boxes.length, mailBefore, "states aren't in the mailbox");
  r = await signed(a, "/f/v1/state/clear", {});
  assert.equal(r.status, 200);
  assert.equal(r.json.cleared, 1);
  assert.equal((await signed(b, "/f/v1/state/get", {})).json.states.length, 0);
  await signed(a, "/f/v1/state/put", { states: [{ to: b.id, data: s1 }] });
  r = await signed(a, "/f/v1/state/clear", { to: [b.id] });
  assert.equal(r.json.cleared, 1);
  await signed(b, "/f/v1/block", { peer: a.id, on: true });
  r = await signed(a, "/f/v1/state/put", { states: [{ to: b.id, data: s1 }] });
  assert.equal(r.json.results[0].ok, true);
  assert.equal((await signed(b, "/f/v1/state/get", {})).json.states.length, 0, "blocked: refused quietly");
  await signed(b, "/f/v1/block", { peer: a.id, on: false });
  await signed(a, "/f/v1/state/put", { states: [{ to: b.id, data: s1 }] });
  await signed(b, "/f/v1/drop", { peer: a.id });
  assert.equal((await signed(b, "/f/v1/state/get", {})).json.states.length, 0, "drop takes states too");
  await signed(a, "/f/v1/state/put", { states: [{ to: b.id, data: s1 }] });
  assert.equal((await signed(b, "/f/v1/state/get", {})).json.states.length, 1);
  console.log("states ok");

  // groups (0.27): one send fans a line out to several mailboxes; a group's list replaces itself in its slot
  const c = await makeAccount();
  r = await signed(c, "/f/v1/register", { signKey: b64url(c.pub) });
  assert.equal(r.status, 200);
  const gid = "0123456789abcdef01234567";
  const beforeB = (await signed(b, "/f/v1/inbox", {})).json.boxes.length;
  const line = (s) => b64url(new TextEncoder().encode(s));
  r = await signed(a, "/f/v1/send", { boxes: [
    { to: b.id, data: line("list 1 for b"), slot: `gr.${gid}`, ttl: 30 * 86400 },
    { to: c.id, data: line("list 1 for c"), slot: `gr.${gid}`, ttl: 30 * 86400 },
  ] });
  assert.ok(r.json.results.every((x) => x.ok), JSON.stringify(r.json));
  r = await signed(a, "/f/v1/send", { boxes: [{ to: b.id, data: line("line for b") }, { to: c.id, data: line("line for c") }] });
  assert.ok(r.json.results.every((x) => x.ok), JSON.stringify(r.json));
  r = await signed(a, "/f/v1/send", { boxes: [
    { to: b.id, data: line("list 2 for b"), slot: `gr.${gid}`, ttl: 30 * 86400 },
    { to: c.id, data: line("list 2 for c"), slot: `gr.${gid}`, ttl: 30 * 86400 },
  ] });
  assert.ok(r.json.results.every((x) => x.ok));
  r = await signed(c, "/f/v1/send", { boxes: [{ to: a.id, data: line("seen 1"), slot: `se.${gid}` }] });
  r = await signed(c, "/f/v1/send", { boxes: [{ to: a.id, data: line("seen 2"), slot: `se.${gid}` }] });
  assert.ok(r.json.results[0].ok);
  const inC = (await signed(c, "/f/v1/inbox", {})).json.boxes.map((x) => Buffer.from(x.data, "base64url").toString());
  assert.deepEqual(inC, ["line for c", "list 2 for c"], "the newest list only, after the line it replaced");
  const inB = (await signed(b, "/f/v1/inbox", {})).json.boxes;
  assert.equal(inB.length - beforeB, 2);
  const seenA = (await signed(a, "/f/v1/inbox", {})).json.boxes.filter((x) => x.slot === `se.${gid}`);
  assert.equal(seenA.length, 1);
  assert.equal(Buffer.from(seenA[0].data, "base64url").toString(), "seen 2");
  r = await signed(a, "/f/v1/send", { boxes: Array.from({ length: 21 }, () => ({ to: b.id, data: line("x") })) });
  assert.equal(r.status, 400, "at most 20 boxes in one send");
  r = await signed(c, "/f/v1/leave", {});
  assert.equal(r.status, 200);
  console.log("groups/fan-out ok");

  // vault
  r = await signed(a, "/f/v1/vault/get", {});
  assert.equal(r.json.data, null);
  r = await signed(a, "/f/v1/vault/put", { data });
  assert.equal(r.status, 200);
  r = await signed(a, "/f/v1/vault/get", {});
  assert.equal(r.json.data, data);
  console.log("vault ok");

  // a second phone restores: the first is signed out
  const a2 = { ...a, device: hex(crypto.getRandomValues(new Uint8Array(16))) };
  r = await signed(a2, "/f/v1/register", { signKey: b64url(a.pub) });
  assert.equal(r.status, 200);
  assert.equal(r.json.moved, true);
  assert.equal(r.json.created, false);
  r = await signed(a, "/f/v1/inbox", {});
  assert.equal(r.status, 409);
  assert.equal(r.json.error, "signed_out");
  r = await signed(a2, "/f/v1/vault/get", {});
  assert.equal(r.json.data, data);
  console.log("restore/sign-out ok");

  // unknown routes and methods
  assert.equal((await call("/f/v1/nope", { method: "POST" })).status, 404);
  assert.equal((await call("/f/v1/inbox", { method: "GET" })).status, 405);

  // leave: both throwaway accounts deleted (a's state at b goes with it)
  r = await signed(a2, "/f/v1/leave", {});
  assert.equal(r.status, 200);
  assert.equal((await signed(b, "/f/v1/state/get", {})).json.states.length, 0, "leave takes your states back");
  r = await signed(b, "/f/v1/leave", {});
  assert.equal(r.status, 200);
  r = await signed(b, "/f/v1/inbox", {});
  assert.equal(r.status, 404);
  console.log("leave ok");
  console.log("ALL OK" + (LIVE ? " (live)" : ""));
}

run().catch((e) => { console.error("FAILED:", e.stack); process.exit(1); });
