// A check of /music/v1/now (music.js): locally with Last.fm faked, or against the live relay.
// Run: node relay/test-music.mjs
// Or:  node relay/test-music.mjs https://haltewekker-relay.tsfaw1.workers.dev
// Also checks the shared vectors (docs/music-vectors.json): the relay's answer to their Last.fm answer.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { music, slimRecent, iso, resetMusic } from "./music.js";

const LIVE = process.argv[2] || null;
const cors = { "Access-Control-Allow-Origin": "*" };
const V = JSON.parse(readFileSync(new URL("../docs/music-vectors.json", import.meta.url), "utf8"));

async function local() {
  // the vectors: Last.fm's answer as the app gets it
  const now = V.now * 1000;
  assert.deepEqual(slimRecent(V.relay.lastfm, "spotify", now), V.relay.spotify);
  assert.deepEqual(slimRecent(V.relay.lastfm, "lastfm", now), V.relay.other);
  assert.deepEqual(slimRecent({ recenttracks: { track: [V.relay.lastfm.recenttracks.track[1]] } }, "spotify", now), V.relay.idle);
  assert.deepEqual(slimRecent({ recenttracks: { track: V.relay.lastfm.recenttracks.track[0] } }, "spotify", now), V.relay.spotify);
  assert.deepEqual(slimRecent({}, "lastfm", now), V.relay.idle);
  assert.equal(iso(V.base.song.seen * 1000), V.music.at);
  // never an earlier track, never another host's cover, never Last.fm's grey star
  const odd = JSON.parse(JSON.stringify(V.relay.lastfm));
  odd.recenttracks.track[0].image = [
    { size: "large", "#text": "https://lastfm.freetls.fastly.net/i/u/174s/0000000000000000000000000000000a.png" },
    { size: "extralarge", "#text": "https://lastfm.freetls.fastly.net/i/u/300x300/2a96cbd8b46e442fc41c2b86b821562f.png" },
  ];
  odd.recenttracks.track[0].url = "https://evil.example/x";
  let s = slimRecent(odd, "lastfm", now);
  assert.equal(s.coverUrl, "https://lastfm.freetls.fastly.net/i/u/174s/0000000000000000000000000000000a.png");
  assert.equal(s.url, undefined);
  odd.recenttracks.track[0].image = [{ size: "extralarge", "#text": "http://lastfm.freetls.fastly.net/x.png" }, { "#text": "https://img.example/x.png" }];
  s = slimRecent(odd, "lastfm", now);
  assert.equal(s.coverUrl, undefined);
  assert.ok(!JSON.stringify(slimRecent(V.relay.lastfm, "spotify", now)).includes("Earlier"));

  // the route
  const asked = [];
  let reply = { status: 200, body: JSON.stringify(V.relay.lastfm) };
  const fake = async (u) => { asked.push(u); return new Response(reply.body, { status: reply.status }); };
  let clock = now;
  const env = { LASTFM_API_KEY: "secret-key" };
  const go = (p, e = env, ip = "1.2.3.4", method = "GET") =>
    music(new Request("https://relay.test" + p, { method, headers: { "CF-Connecting-IP": ip } }), e, new URL("https://relay.test" + p), cors, fake, () => clock);

  assert.equal(await go("/music/v1/other"), null);
  assert.equal((await go("/music/v1/now")).status, 400);
  assert.equal((await go("/music/v1/now?user=a")).status, 400);
  assert.equal((await go("/music/v1/now?user=1abc")).status, 400);
  assert.equal((await go("/music/v1/now?user=abc%26x%3D1")).status, 400);
  assert.equal((await go("/music/v1/now?user=abcdefghijklmnop")).status, 400);
  assert.equal((await go("/music/v1/now?user=test&app=deezer")).status, 400);
  assert.equal((await go("/music/v1/now?user=test&x=1")).status, 400);
  assert.equal((await go("/music/v1/now?user=test", env, "1.2.3.4", "POST")).status, 405);
  // no key: 503 not configured, and Last.fm isn't asked
  let r = await go("/music/v1/now?user=test", {});
  assert.equal(r.status, 503);
  assert.equal((await r.json()).error, "not_configured");
  assert.equal(asked.length, 0);

  r = await go("/music/v1/now?user=Test_1&app=spotify");
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("Content-Type"), "application/json");
  assert.equal(r.headers.get("Access-Control-Allow-Origin"), "*");
  assert.deepEqual(await r.json(), V.relay.spotify);
  assert.equal(asked.length, 1);
  assert.equal(asked[0], "https://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=Test_1&limit=1&format=json&api_key=secret-key");
  // the key never goes back to the app
  r = await go("/music/v1/now?user=test_1&app=spotify");
  assert.ok(!(await r.text()).includes("secret-key"));
  // 30 s per user (any case): Last.fm asked once
  assert.equal(asked.length, 1);
  r = await go("/music/v1/now?user=Test_1");
  assert.deepEqual(await r.json(), V.relay.other);
  assert.equal(asked.length, 2);
  clock += 31_000;
  await go("/music/v1/now?user=Test_1&app=spotify");
  assert.equal(asked.length, 3);

  // Last.fm's errors
  reply = { status: 404, body: '{"error":6,"message":"User not found"}' };
  assert.equal((await go("/music/v1/now?user=nobody")).status, 404);
  reply = { status: 403, body: '{"error":17,"message":"Login: User required to be logged in"}' };
  assert.equal((await go("/music/v1/now?user=hidden")).status, 403);
  reply = { status: 403, body: '{"error":10,"message":"Invalid API key"}' };
  r = await go("/music/v1/now?user=badkey");
  assert.equal(r.status, 503);
  assert.equal((await r.json()).error, "not_configured");
  reply = { status: 500, body: "oops" };
  assert.equal((await go("/music/v1/now?user=broken")).status, 502);
  const n = asked.length;
  assert.equal((await go("/music/v1/now?user=broken")).status, 502);
  assert.equal(asked.length, n + 1, "a failure isn't kept");
  const boom = async () => { throw new Error("down"); };
  r = await music(new Request("https://relay.test/music/v1/now?user=down"), env, new URL("https://relay.test/music/v1/now?user=down"), cors, boom, () => clock);
  assert.equal(r.status, 502);
  reply = { status: 200, body: JSON.stringify({ recenttracks: { track: [] } }) };
  r = await go("/music/v1/now?user=quiet");
  assert.deepEqual(await r.json(), { nowPlaying: false, at: iso(clock) });

  // 30 a minute per network address
  resetMusic();
  reply = { status: 200, body: JSON.stringify(V.relay.lastfm) };
  for (let i = 0; i < 30; i++) assert.equal((await go("/music/v1/now?user=many", env, "9.9.9.9")).status, 200);
  assert.equal((await go("/music/v1/now?user=many", env, "9.9.9.9")).status, 429);
  assert.equal((await go("/music/v1/now?user=many", env, "8.8.8.8")).status, 200);
  clock += 60_000;
  assert.equal((await go("/music/v1/now?user=many", env, "9.9.9.9")).status, 200);

  // wired in the worker (which needs Cloudflare's runtime to load)
  const w = readFileSync(new URL("./worker.js", import.meta.url), "utf8");
  assert.ok(w.includes('import { music } from "./music.js";') && w.includes("await music(request, env, url, cors)"));
  console.log("local: ok");
}

async function live(base) {
  const get = async (p) => { const r = await fetch(base + p); return { status: r.status, text: await r.text() }; };
  const d = await get("/ns/departures?station=BD");
  console.log("/ns/departures?station=BD", d.status);
  assert.equal(d.status, 200);
  const m = await get("/music/v1/now?user=test");
  console.log("/music/v1/now?user=test", m.status, m.text.slice(0, 200));
  assert.ok(m.status === 503 || m.status === 200 || m.status === 404 || m.status === 403, "503 until LASTFM_API_KEY is set");
  const b = await get("/music/v1/now?user=x");
  assert.equal(b.status, 400);
  console.log("live: ok");
}

if (LIVE) await live(LIVE.replace(/\/$/, "")); else await local();
