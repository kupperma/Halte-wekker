// A check of /rail/v1/side (rail.js): the side rule on trimmed OpenStreetMap data of four stations (relay/test-rail/,
// © OpenStreetMap contributors, ODbL), made-up cases, and the route with Overpass and the Durable Object faked.
// Run: node relay/test-rail.mjs
// Or:  node relay/test-rail.mjs https://haltewekker-relay.tsfaw1.workers.dev   (asks the live relay for a known case)
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { trim, sideOf, refMatch, normTrack, parsePoint, overpassQuery, stationKey, seedFor, rail, RailCore, USER_AGENT, OVERPASS_ALL } from "./rail.js";
import { SEED } from "./rail-seed/index.js";

const LIVE = process.argv[2] || null;
const here = dirname(fileURLToPath(import.meta.url));
const fixture = (n) => JSON.parse(readFileSync(join(here, "test-rail", `${n}.json`), "utf8"));
const P = (lat, lon) => ({ lat, lon });

// The stations, with the stop before on each side (public stations).
const AT = {
  breda: P(51.5955, 4.7799), "s-hertogenbosch": P(51.6906, 5.2936), eindhoven: P(51.4433, 5.4813), tilburg: P(51.5605, 5.0838),
};
const FROM = {
  tilburgToBreda: P(51.5458, 4.9339), ettenLeur: P(51.5753, 4.6385),
  vught: P(51.6614, 5.2903), zaltbommel: P(51.81, 5.249), rosmalen: P(51.7166, 5.3667),
  strijpS: P(51.4504, 5.4568), helmond: P(51.4756, 5.6617), best: P(51.5089, 5.3896),
  tilburgUni: P(51.5649, 5.0478), oisterwijk: P(51.5795, 5.1953),
};

function rules() {
  assert.equal(normTrack(" Spoor 4A "), "4a");
  assert.equal(refMatch("4", "4"), 2);
  assert.equal(refMatch("3;4", "4"), 2);
  assert.equal(refMatch("4a", "4"), 1);
  assert.equal(refMatch("4", "4a"), 1);
  assert.equal(refMatch("4b", "4a"), 0);
  assert.equal(refMatch("14", "4"), 0);
  assert.deepEqual(parsePoint("51.69,5.29"), P(51.69, 5.29));
  assert.equal(parsePoint("51.69"), null);
  assert.equal(parsePoint("x,y"), null);
  assert.equal(parsePoint("95,5"), null);
  assert.equal(stationKey("bd", P(51.5955, 4.7799)), "st:BD@51.60,4.78");
  assert.equal(stationKey("Den Bosch", P(51.69, 5.29)), "st:den bosch@51.69,5.29");
  const oq = overpassQuery(P(51.5955, 4.7799));
  assert.ok(oq.startsWith("[out:json][timeout:15][bbox:51.59188,4.77412,51.59912,4.78568];("), oq);
  assert.ok(oq.endsWith(";);out tags geom(51.59007,4.77122,51.60093,4.78858);"), oq);
}

/** Each station: [track, from, side, confidence]. The two sides of an island give opposite answers, and the other
 *  way round flips each; 's-Hertogenbosch track 1 is at the station hall, on the east: on the right going north. */
const CASES = {
  breda: [
    ["3", "tilburgToBreda", "right", "high"], ["4", "tilburgToBreda", "left", "high"], ["5", "tilburgToBreda", "right", "high"],
    ["6", "tilburgToBreda", "left", "high"], ["7", "tilburgToBreda", "right", "high"], ["8", "tilburgToBreda", "left", "high"],
    ["3", "ettenLeur", "left", "high"], ["4", "ettenLeur", "right", "high"], ["8", "ettenLeur", "right", "high"],
  ],
  "s-hertogenbosch": [
    ["1", "vught", "right", "high"], ["1", "zaltbommel", "left", "high"],
    ["3a", "vught", "left", "high"], ["3b", "vught", "left", "high"], ["4a", "vught", "right", "high"], ["4b", "zaltbommel", "left", "high"],
    ["6a", "vught", "left", "high"], ["7b", "vught", "right", "high"], ["7a", "rosmalen", "left", "high"],
    ["3", "vught", "left", "low"],          // no part letter: both parts, a looser match
  ],
  eindhoven: [
    ["1", "strijpS", "left", "high"], ["2", "strijpS", "right", "high"], ["3", "helmond", "right", "high"],
    ["4", "helmond", "left", "high"], ["5", "strijpS", "left", "high"], ["6", "helmond", "left", "high"],
    ["1", "best", "left", "low"],           // the line from Best bends into the station: a guess
  ],
  tilburg: [
    ["2", "tilburgUni", "left", "high"], ["3", "tilburgUni", "right", "high"], ["4", "tilburgUni", "left", "high"],
    ["2", "oisterwijk", "right", "high"], ["3", "oisterwijk", "left", "high"],
  ],
};

function fixtures() {
  let n = 0;
  for (const [st, cases] of Object.entries(CASES)) {
    const d = trim(fixture(st));
    assert.ok(d.platforms.length >= 3 && d.rails.length >= 10, st);
    for (const [track, from, side, confidence] of cases) {
      const a = sideOf(d, track, FROM[from], AT[st]);
      assert.equal(a.side, side, `${st} ${track} from ${from}`);
      assert.equal(a.confidence, confidence, `${st} ${track} from ${from}`);
      assert.equal(a.platformRef, normTrack(track), `${st} ${track}`);
      n++;
    }
    // a track it hasn't: unknown
    assert.deepEqual(sideOf(d, "19", FROM.vught, AT[st]).side, "unknown");
  }
  // the stop before too near to say a way
  assert.equal(sideOf(trim(fixture("breda")), "3", P(51.5957, 4.7801), AT.breda).why, "no_direction");
  return n;
}

// Made-up stations: rails along x (east), the station at (0, 0); metres to degrees near 52° N.
const O = P(52, 5);
const m = (x, y) => ({ lat: O.lat + y / 110540, lon: O.lon + x / (111320 * Math.cos((O.lat * Math.PI) / 180)) });
const way = (tags, pts) => ({ type: "way", tags, geometry: pts.map(([x, y]) => m(x, y)) });
const box = (x0, y0, x1, y1) => [[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]];
const rail_ = (y, extra = {}) => way({ railway: "rail", ...extra }, [[-400, y], [400, y]]);
const plat = (ref, y0, y1, extra = {}) => way({ railway: "platform", public_transport: "platform", ref, ...extra }, box(-150, y0, 150, y1));
const west = m(-5000, 0), east = m(5000, 0);

function madeUp() {
  // a side platform north of the track: going east, on the left
  let d = trim({ elements: [rail_(0), plat("1", 2, 8)] });
  assert.deepEqual(sideOf(d, "1", west, O), { side: "left", confidence: "high", platformRef: "1" });
  assert.equal(sideOf(d, "1", east, O).side, "right");
  // doors on both sides: a platform each side with the same ref
  d = trim({ elements: [rail_(0), plat("2", 2, 8), plat("2", -8, -2)] });
  assert.equal(sideOf(d, "2", west, O).side, "both");
  // one area for an island between two tracks ("3;4"): which track is which can't be told
  d = trim({ elements: [rail_(0), rail_(12), plat("3;4", 2, 10)] });
  assert.equal(sideOf(d, "3", west, O).side, "unknown");
  assert.equal(sideOf(d, "3", west, O).why, "ambiguous");
  // the same island with its halves apart: each says
  d = trim({ elements: [rail_(0), rail_(12), plat("3", 2, 6), plat("4", 6, 10)] });
  assert.equal(sideOf(d, "3", west, O).side, "left");
  assert.equal(sideOf(d, "4", west, O).side, "right");
  // a rail that says its track wins over a nearer one (and the island area is no longer in doubt)
  d = trim({ elements: [rail_(0, { "railway:track_ref": "3" }), rail_(12, { "railway:track_ref": "4" }), plat("3;4", 2, 10)] });
  assert.equal(sideOf(d, "4", west, O).side, "right");
  assert.equal(sideOf(d, "3", west, O).side, "left");
  // a platform edge line (and the name "Spoor 5" when there is no ref)
  d = trim({ elements: [rail_(0), way({ railway: "platform_edge", name: "Spoor 5" }, [[-100, -2], [100, -2]])] });
  assert.equal(sideOf(d, "5", west, O).side, "right");
  // a multipolygon platform (a relation)
  d = trim({ elements: [rail_(0), { type: "relation", tags: { railway: "platform", ref: "6" },
    members: [{ role: "outer", geometry: box(-50, 3, 50, 9).map(([x, y]) => m(x, y)) }] }] });
  assert.equal(sideOf(d, "6", west, O).side, "left");
  // a platform far from any rail, a train across the track, crossovers left out
  d = trim({ elements: [rail_(0), plat("7", 40, 46), way({ railway: "rail", service: "crossover" }, [[-50, 0], [50, 12]])] });
  assert.equal(d.rails.length, 1);
  assert.equal(sideOf(d, "7", west, O).side, "unknown");
  d = trim({ elements: [rail_(0), plat("1", 2, 8)] });
  assert.equal(sideOf(d, "1", m(0, -5000), O).side, "unknown");
  // a way bent from the stop before: a guess
  assert.deepEqual(sideOf(d, "1", m(-2000, -4500), O), { side: "left", confidence: "low", platformRef: "1" });
  // nothing at all
  assert.equal(sideOf(trim({}), "1", west, O).side, "unknown");
  assert.equal(sideOf(trim({ elements: [{ type: "way", tags: { railway: "platform" }, geometry: [] }] }), "1", west, O).side, "unknown");
}

// MARK: the route, with Overpass and the Durable Object faked

class FakeStorage {
  constructor() { this.map = new Map(); }
  async get(k) { const v = this.map.get(k); return v === undefined ? undefined : structuredClone(v); }
  async put(k, v) { this.map.set(k, structuredClone(v)); }
}

async function route() {
  const cors = { "Access-Control-Allow-Origin": "*" };
  let clock = 1_000_000, answer = { status: 200, body: JSON.stringify(fixture("breda")) };
  const asked = [];
  const overpass = async (u, init) => {
    asked.push({ u, init });
    await new Promise((r) => setTimeout(r, 5));
    return new Response(answer.body, { status: answer.status });
  };
  const objects = new Map();
  const RAIL = {
    idFromName: (n) => n,
    get: (id) => ({
      fetch: (u, init) => {
        // no bundled stations here: this is Overpass and what is kept (the seed has its own checks below)
        if (!objects.has(id)) objects.set(id, new RailCore({ storage: new FakeStorage() }, {}, overpass, () => clock, [], 50));
        return objects.get(id).fetch(new Request(u, init));
      },
    }),
  };
  const env = { RAIL };
  const go = (q, e = env) => rail(new Request("https://relay.test/rail/v1/side?" + q), e, new URL("https://relay.test/rail/v1/side?" + q), cors);
  const q = (track, from = FROM.tilburgToBreda) => `station=BD&track=${track}&from=${from.lat},${from.lon}&at=${AT.breda.lat},${AT.breda.lon}`;

  // bad questions
  for (const bad of ["station=BD&track=4", "station=BD&track=4&from=1,2&at=x", "station=<b>&track=4&from=1,2&at=1,2",
    "station=BD&track=444&from=1,2&at=1,2", q("4") + "&me=1"]) assert.equal((await go(bad)).status, 400, bad);
  assert.equal((await go(q("4"), {})).status, 503);

  // two at once: one Overpass request; then from what's kept
  const [a, b] = await Promise.all([go(q("4")), go(q("3"))]);
  assert.equal(a.status, 200);
  assert.deepEqual(await a.json(), { side: "left", confidence: "high", platformRef: "4" });
  assert.deepEqual(await b.json(), { side: "right", confidence: "high", platformRef: "3" });
  assert.equal(a.headers.get("Cache-Control"), "max-age=86400");
  assert.equal(asked.length, 1);
  assert.ok(asked[0].u.startsWith("https://overpass-api.de/api/interpreter?data=%5Bout%3Ajson%5D"));
  assert.equal(asked[0].init.method, "GET");
  assert.equal(asked[0].init.headers["User-Agent"], USER_AGENT);
  assert.ok(decodeURIComponent(asked[0].u).includes('way["railway"~"^(rail|platform|platform_edge)$"]'));
  assert.equal((await (await go(q("8", FROM.ettenLeur))).json()).side, "right");
  assert.equal(asked.length, 1);
  // 30 days later: asked again
  clock += 31 * 86400_000;
  await go(q("4"));
  assert.equal(asked.length, 2);

  // a busy Overpass: 503 osm_busy, and not asked again for a while
  const other = (s) => `station=${s}&track=1&from=51.66,5.29&at=51.69,5.29`;
  answer = { status: 429, body: "slow down" };
  let r = await go(other("HT"));
  assert.equal(r.status, 503);
  const j = await r.json();
  assert.equal(j.side, "unknown");
  assert.equal(j.why, "osm_busy");
  assert.equal(j.retryAfter, 1800);
  assert.equal(j.osm, "429,429,429");
  assert.ok(asked[3].u.startsWith("https://maps.mail.ru/osm/tools/overpass/api/interpreter?data="));
  assert.ok(asked[4].u.startsWith("https://overpass.private.coffee/api/interpreter?data="));
  await go(other("HT"));
  assert.equal(asked.length, 5);
  clock += 31 * 60_000;
  answer = { status: 200, body: JSON.stringify(fixture("s-hertogenbosch")) };
  r = await go(other("HT"));
  assert.equal(r.status, 200);
  assert.equal(asked.length, 6);
  // nothing in OSM: kept too (unknown), not asked again
  answer = { status: 200, body: '{"elements":[]}' };
  r = await go(other("XYZ"));
  assert.equal((await r.json()).side, "unknown");
  await go(other("XYZ"));
  assert.equal(asked.length, 7);
}

// MARK: the bundled seed

/** The stop before on each side of each seeded station (public stations; a few just off the seed). */
const ST = Object.fromEntries(SEED.map((st) => [st.code, P(...st.at)]));
const NEXT = {
  BD: [P(51.6057, 4.7214), "GZ"], GZ: ["BD", "TBR"], TBR: ["GZ", "TBU"], TBU: ["TBR", "TB"], TB: ["TBU", "OT"], OT: ["TB", "BTL"],
  BTL: ["OT", "VG"], VG: ["BTL", "HT"], HT: ["VG", P(51.7152, 5.3696)], BET: ["BTL", "EHS"], EHS: ["BET", "EHV"], EHV: ["EHS", P(51.4756, 5.6617)],
};
const flip = { left: "right", right: "left", both: "both" };

function seed() {
  const codes = SEED.map((st) => st.code).sort();
  assert.deepEqual(codes, ["BD", "BET", "BTL", "EHS", "EHV", "GZ", "HT", "OT", "TB", "TBR", "TBU", "VG"]);
  let n = 0;
  for (const st of SEED) {
    assert.match(st.attribution, /OpenStreetMap contributors, ODbL/);
    const at = ST[st.code];
    const [a, b] = NEXT[st.code].map((x) => (typeof x === "string" ? ST[x] : x));
    // found by the station's place, even a few hundred metres off; not by a place far away
    const data = seedFor(P(at.lat + 0.003, at.lon));
    assert.ok(data && data.platforms === st.platforms, st.code);
    const tracks = [...new Set(st.platforms.flatMap((p) => p.refs.split(";")))].filter((r) => /^\d/.test(r));
    assert.ok(tracks.length >= 2, st.code);
    const sideAt = {};
    for (const track of tracks) {
      const one = sideOf(data, track, a, at), other = sideOf(data, track, b, at);
      assert.ok(["left", "right", "both"].includes(one.side), `${st.code} ${track} from one side: ${JSON.stringify(one)}`);
      assert.equal(other.side, flip[one.side], `${st.code} ${track}: the other way round`);
      sideAt[track] = one.side;
      n++;
    }
    // the two sides of an island (two platform areas side by side, one track each): opposite
    const xy = (p) => [(p[1] - at.lon) * 111320 * Math.cos((at.lat * Math.PI) / 180), (p[0] - at.lat) * 110540];
    const mid = (pl) => { const q = pl.pts.map(xy); return q.reduce((s, v) => [s[0] + v[0] / q.length, s[1] + v[1] / q.length], [0, 0]); };
    for (const p of st.platforms) for (const q of st.platforms) {
      if (p === q || p.refs.includes(";") || q.refs.includes(";")) continue;
      const [x0, y0] = mid(p), [x1, y1] = mid(q);
      if (Math.hypot(x1 - x0, y1 - y0) > 12 || p.refs[0] === q.refs[0] && p.refs.length !== q.refs.length) continue;
      if (sideAt[p.refs] && sideAt[q.refs] && p.refs.replace(/[a-z]$/, "") !== q.refs.replace(/[a-z]$/, ""))
        assert.equal(sideAt[q.refs], flip[sideAt[p.refs]], `${st.code} island ${p.refs}/${q.refs}`);
    }
  }
  assert.equal(seedFor(P(52.3791, 4.9003)), null);           // Amsterdam: not bundled
  // the known answers hold on the seed too (Breda: the same as on the fixture)
  const bd = seedFor(AT.breda);
  for (const [track, from, side] of CASES.breda) assert.equal(sideOf(bd, track, FROM[from], AT.breda).side, side, `seed BD ${track}`);
  return n;
}

/** What is kept, then the seed, then Overpass (here failing every time). */
async function lookupOrder() {
  let clock = 5_000_000;
  const asked = [];
  const failing = async (u) => { asked.push(u); return new Response("<html>521</html>", { status: 521 }); };
  const store = new FakeStorage();
  const core = new RailCore({ storage: store }, {}, failing, () => clock, SEED, 5);
  const ask = async (at) => (await core.fetch(new Request("https://rail.internal/data", { method: "POST", body: JSON.stringify(at) }))).json();

  // Breda after Overpass failed for it before (as live): the seed answers, Overpass isn't asked, it's kept
  await store.put("d", { retryAt: clock + 600_000, osm: "timeout@20000,521,521" });
  let got = await ask(AT.breda);
  assert.ok(got.data && got.data.platforms.length >= 6);
  assert.equal(asked.length, 0);
  assert.equal((await store.get("d")).from, "seed");
  assert.equal(sideOf(got.data, "3", FROM.tilburgToBreda, AT.breda).side, "right");
  // kept first: what the Durable Object has wins over the seed
  const mine = { platforms: [{ refs: "9", pts: [[51.5955, 4.7799]], edge: false }], rails: [] };
  await store.put("d", { data: mine, exp: clock + 1000 });
  assert.deepEqual((await ask(AT.breda)).data, mine);
  // an empty answer kept from Overpass doesn't hide the seed
  await store.put("d", { data: { platforms: [], rails: [] }, exp: clock + 1000 });
  assert.ok((await ask(AT.breda)).data.platforms.length >= 6);
  assert.equal(asked.length, 0);

  // not bundled: Overpass, every instance (raced), all failing: no data, kept as busy, not asked again for a while
  const ams = P(52.3791, 4.9003);
  const s2 = new FakeStorage();
  const c2 = new RailCore({ storage: s2 }, {}, failing, () => clock, SEED, 5);
  const ask2 = async () => (await c2.fetch(new Request("https://rail.internal/data", { method: "POST", body: JSON.stringify(ams) }))).json();
  got = await ask2();
  assert.equal(got.data, undefined);
  assert.equal(got.osm, "521,521,521");
  assert.equal(got.retryAfter, 600);
  assert.equal(asked.length, 3);
  assert.deepEqual(asked.map((u) => u.split("?")[0]), OVERPASS_ALL);
  await ask2();
  assert.equal(asked.length, 3);

  // the race: a slow first instance doesn't hold up a quick second one, and is stopped once that answered
  const slowFast = async (u, init) => {
    asked.push(u);
    if (u.startsWith(OVERPASS_ALL[0])) {
      return await new Promise((res, rej) => init.signal.addEventListener("abort", () => rej(Object.assign(new Error("stop"), { name: "AbortError" }))));
    }
    return new Response(JSON.stringify(fixture("tilburg")), { status: 200 });
  };
  const c3 = new RailCore({ storage: new FakeStorage() }, {}, slowFast, () => clock, [], 5);
  const t0 = Date.now();
  got = await (await c3.fetch(new Request("https://rail.internal/data", { method: "POST", body: JSON.stringify(AT.tilburg) }))).json();
  assert.ok(got.data && got.data.platforms.length >= 3);
  assert.ok(Date.now() - t0 < 2000);
  assert.equal(asked.length, 5);      // the first and the second; the third never started
  // a 200 that ran out of time (a "remark", part of the data) is no answer
  const partial = async () => new Response('{"elements":[],"remark":"runtime error: Query timed out in \\"query\\" at line 1"}', { status: 200 });
  const c4 = new RailCore({ storage: new FakeStorage() }, {}, partial, () => clock, [], 5);
  got = await (await c4.fetch(new Request("https://rail.internal/data", { method: "POST", body: JSON.stringify(ams) }))).json();
  assert.equal(got.osm, "partial,partial,partial");
}

async function live() {
  const q = `station=BD&track=4&from=${FROM.tilburgToBreda.lat},${FROM.tilburgToBreda.lon}&at=${AT.breda.lat},${AT.breda.lon}`;
  for (let i = 0; i < 3; i++) {
    const r = await fetch(`${LIVE}/rail/v1/side?${q}`);
    const body = await r.text();
    console.log(`live /rail/v1/side BD 4 from Tilburg: ${r.status} ${body}`);
    if (r.status === 200) { assert.equal(JSON.parse(body).side, "left"); return; }
    await new Promise((res) => setTimeout(res, 5000));
  }
  assert.fail("no answer from the live relay");
}

/** docs/door-side-vectors.json: the relay's answers the apps' vectors start from. */
function vectors() {
  const v = JSON.parse(readFileSync(join(here, "..", "docs", "door-side-vectors.json"), "utf8"));
  for (const c of v.relay) {
    const a = sideOf(trim(fixture(c.fixture)), c.track, parsePoint(c.from), parsePoint(c.at));
    assert.equal(a.side, c.side, `${c.station} ${c.track}`);
    assert.equal(a.confidence, c.confidence, `${c.station} ${c.track}`);
  }
}

rules();
vectors();
const n = fixtures();
madeUp();
const ns = seed();
await route();
await lookupOrder();
console.log(`rail: ok (${n} station cases on OSM data, ${ns} seeded tracks both ways, made-up cases, the route, the lookup order)`);
if (LIVE) await live();
