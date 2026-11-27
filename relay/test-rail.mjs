// A check of /rail/v1/side (rail.js): the side rule on trimmed OpenStreetMap data of four stations (relay/test-rail/,
// © OpenStreetMap contributors, ODbL), made-up cases, and the route with Overpass and the Durable Object faked.
// Run: node relay/test-rail.mjs
// Or:  node relay/test-rail.mjs https://haltewekker-relay.tsfaw1.workers.dev   (asks the live relay for a known case)
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { trim, sideOf, refMatch, normTrack, parsePoint, overpassQuery, stationKey, rail, RailCore, USER_AGENT } from "./rail.js";

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
  assert.ok(overpassQuery(P(51.5955, 4.7799)).startsWith("[out:json][timeout:25][bbox:51.59188,4.77412,51.59912,4.78568];("));
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
        if (!objects.has(id)) objects.set(id, new RailCore({ storage: new FakeStorage() }, {}, overpass, () => clock));
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
  assert.ok(decodeURIComponent(asked[0].u).includes('way["railway"="rail"];);out tags geom;'));
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
await route();
console.log(`rail: ok (${n} station cases on OSM data, made-up cases, the route)`);
if (LIVE) await live();
