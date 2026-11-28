// A check of /be/liveboard, /be/vehicle and /be/composition (irail.js): locally on trimmed real iRail answers
// (test-irail/), with iRail faked, or against the live relay.
// Run: node relay/test-irail.mjs
// Or:  node relay/test-irail.mjs https://haltewekker-relay.tsfaw1.workers.dev
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { be, forget, slimLiveboard, slimVehicle, slimComposition, upstream, uicOf, platform, USER_AGENT } from "./irail.js";

const LIVE = process.argv[2] || null;
const cors = { "Access-Control-Allow-Origin": "*" };
const fx = (n) => JSON.parse(readFileSync(new URL(`./test-irail/${n}.json`, import.meta.url), "utf8"));

function pure() {
  assert.equal(uicOf({ id: "BE.NMBS.008821006" }), "8821006");
  assert.equal(uicOf({ "@id": "http://irail.be/stations/NMBS/008400131" }), "8400131");
  assert.equal(uicOf({ id: "x" }), null);
  assert.equal(platform("?"), null);
  assert.equal(platform(" 12 "), "12");

  // Antwerpen-Centraal: platform, a changed platform, delay, occupancy, a cancellation
  const a = slimLiveboard(fx("liveboard-antwerpen"));
  assert.deepEqual(a.station, { uic: "8821006", name: "Antwerpen-Centraal", lat: 51.2172, lon: 4.421101 });
  assert.equal(a.departures.length, 5);
  const s33 = a.departures[0];
  assert.deepEqual(s33, {
    num: "2962", type: "S33", name: "S33 2962", vehicle: "BE.NMBS.S332962", to: "Herentals", toUic: "8821717",
    planned: "2026-11-28T11:23:00Z", delay: 0, platform: "1", platformChanged: false, canceled: false, left: false, occupancy: "low",
  });
  const ic = a.departures.find((d) => d.num === "3334");
  assert.equal(ic.platform, "24");
  assert.equal(ic.platformChanged, true);
  const ec = a.departures.find((d) => d.num === "9235");
  assert.equal(ec.to, "Breda");
  assert.equal(ec.toUic, "8400131");
  assert.equal(ec.occupancy, null);
  const late = a.departures.find((d) => d.num === "2562");
  assert.equal(late.delay, 60);
  assert.equal(late.to, "Roosendaal");
  assert.equal(a.departures.find((d) => d.num === "2862").canceled, true);

  const b = slimLiveboard(fx("liveboard-brussel-zuid"));
  assert.equal(b.station.uic, "8814001");
  assert.equal(b.departures.find((d) => d.num === "3333").delay, 180);
  assert.equal(b.departures.find((d) => d.num === "1533").occupancy, "high");
  assert.equal(b.departures.find((d) => d.num === "9334").type, "EUR");

  // EC 9235 Brussel-Noord → Breda: every stop, Breda (NL) without a platform
  const v = slimVehicle(fx("vehicle-ec9235"));
  assert.equal(v.num, "9235");
  assert.equal(v.type, "EC");
  assert.equal(v.vehicle, "BE.NMBS.EC9235");
  assert.equal(v.stops.length, 6);
  assert.deepEqual(v.stops[0], {
    uic: "8812005", name: "Brussels-North", lat: 50.859663, lon: 4.360846, arrival: "2026-11-28T10:36:00Z", departure: "2026-11-28T10:36:00Z",
    arrivalDelay: 0, departureDelay: 60, platform: "5", platformChanged: false, arrivalCanceled: false, departureCanceled: false, arrived: true, left: true,
  });
  assert.equal(v.stops[5].uic, "8400131");
  assert.equal(v.stops[5].platform, null);
  assert.ok(v.stops.every((s) => s.uic && s.arrival));
  assert.equal(JSON.stringify(v).includes("locationX"), false);     // no make-believe GPS

  const c = slimComposition(fx("composition-ic2912"), "2912");
  assert.equal(c.num, "2912");
  assert.equal(c.segments.length, 1);
  assert.equal(c.segments[0].from.uic, "8821006");
  assert.equal(c.cars, 6);
  assert.equal(c.seats, 2 * (99 + 77 + 32 + 40));
  assert.deepEqual(c.segments[0].units[2], { type: "AM80M", sub: "c", first: 32, second: 40, length: 25, toilets: true, bikes: false, prm: false });

  // the questions
  const up = (p) => upstream(new URL("https://relay.test" + p));
  assert.equal(up("/be/liveboard?station=Antwerpen-Centraal").url,
    "https://api.irail.be/v1/liveboard/?station=Antwerpen-Centraal&arrdep=departure&format=json&lang=en&alerts=false");
  assert.match(up("/be/liveboard?station=Li%C3%A8ge-Guillemins").url, /station=Li%C3%A8ge-Guillemins&/);
  assert.match(up("/be/liveboard?id=8821006").url, /\?id=BE\.NMBS\.008821006&/);
  assert.match(up("/be/liveboard?id=BE.NMBS.008814001").url, /\?id=BE\.NMBS\.008814001&/);
  assert.equal(up("/be/liveboard"), null);
  assert.equal(up("/be/liveboard?station=a"), null);
  assert.equal(up("/be/liveboard?station=<script>"), null);
  assert.equal(up("/be/liveboard?id=88"), null);
  assert.equal(up("/be/liveboard?id=8821006&station=X"), null);
  assert.equal(up("/be/liveboard?station=Gent&lat=51"), null);
  assert.equal(up("/be/vehicle?id=9235").url, "https://api.irail.be/v1/vehicle/?id=BE.NMBS.9235&format=json&lang=en&alerts=false");
  assert.equal(up("/be/vehicle?id=ic2912&date=281126").url, "https://api.irail.be/v1/vehicle/?id=BE.NMBS.IC2912&date=281126&format=json&lang=en&alerts=false");
  assert.match(up("/be/vehicle?id=BE.NMBS.S332962").url, /id=BE\.NMBS\.S332962&/);
  assert.equal(up("/be/vehicle?id=9235&date=2026"), null);
  assert.equal(up("/be/vehicle?id=../x"), null);
  assert.equal(up("/be/composition?id=IC2912").url, "https://api.irail.be/v1/composition/?id=IC2912&format=json");
  assert.equal(up("/be/composition?id=9235&date=281126"), null);
  assert.equal(up("/be/other"), null);
}

async function local() {
  forget();
  const asked = [];
  let answer = () => new Response(JSON.stringify(fx("liveboard-antwerpen")), { status: 200 });
  const fake = async (u, init) => { asked.push({ u, ua: init?.headers?.["User-Agent"] }); return answer(u); };
  let t = 1_000_000;
  const go = (p) => be(new URL("https://relay.test" + p), cors, { fetchImpl: fake, cache: null, now: () => t });

  assert.equal((await go("/be/liveboard?station=%3Cx%3E")).status, 400);
  assert.equal(asked.length, 0);
  let r = await go("/be/liveboard?station=Antwerpen-Centraal");
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("Content-Type"), "application/json");
  assert.equal(r.headers.get("Cache-Control"), "max-age=30");
  assert.equal(r.headers.get("Access-Control-Allow-Origin"), "*");
  assert.equal((await r.json()).departures.length, 5);
  assert.equal(asked[0].ua, USER_AGENT);
  assert.ok(!/@|mail/i.test(USER_AGENT));
  // kept 30 s: not asked again
  t += 20_000;
  assert.equal((await go("/be/liveboard?station=Antwerpen-Centraal")).status, 200);
  assert.equal(asked.length, 1);
  t += 11_000;
  await go("/be/liveboard?station=Antwerpen-Centraal");
  assert.equal(asked.length, 2);

  // vehicle, composition
  answer = (u) => new Response(JSON.stringify(u.includes("/vehicle/") ? fx("vehicle-ec9235") : fx("composition-ic2912")), { status: 200 });
  r = await go("/be/vehicle?id=EC9235&date=281126");
  assert.equal((await r.json()).stops.length, 6);
  r = await go("/be/composition?id=IC2912");
  assert.equal((await r.json()).cars, 6);

  // not known: 404, kept too
  answer = () => new Response('{"error":404,"message":"Vehicle not found"}', { status: 404 });
  r = await go("/be/vehicle?id=1");
  assert.equal(r.status, 404);
  assert.deepEqual(await r.json(), { error: "not_found" });
  // iRail's other trouble: 502, not kept
  answer = () => new Response("oops", { status: 500 });
  assert.equal((await go("/be/vehicle?id=2")).status, 502);
  answer = () => new Response("not json", { status: 200 });
  assert.equal((await go("/be/vehicle?id=3")).status, 502);
  answer = () => { throw new Error("down"); };
  assert.equal((await go("/be/vehicle?id=4")).status, 502);
  // a 429: quiet for 10 s, nothing asked meanwhile
  answer = () => new Response("slow down", { status: 429 });
  r = await go("/be/vehicle?id=5");
  assert.equal(r.status, 503);
  assert.equal((await r.json()).retryAfter, 10);
  const n = asked.length;
  t += 5_000;
  assert.equal((await go("/be/vehicle?id=6")).status, 503);
  assert.equal(asked.length, n);
  t += 6_000;
  answer = () => new Response(JSON.stringify(fx("vehicle-ec9235")), { status: 200 });
  assert.equal((await go("/be/vehicle?id=6")).status, 200);
  console.log("irail local: ok");
}

async function live(base) {
  const get = async (p) => {
    const r = await fetch(base + p);
    return { status: r.status, json: r.headers.get("Content-Type")?.includes("json") ? await r.json() : null };
  };
  let a = await get("/be/liveboard?station=Antwerpen-Centraal");
  assert.equal(a.status, 200);
  assert.equal(a.json.station.uic, "8821006");
  console.log(`live /be/liveboard Antwerpen-Centraal: ${a.json.departures.length} departures, first ${JSON.stringify(a.json.departures[0])}`);
  a = await get("/be/liveboard?id=8814001");
  assert.equal(a.status, 200);
  console.log(`live /be/liveboard Brussel-Zuid: ${a.json.departures.length} departures`);
  const first = a.json.departures.find((d) => d.num);
  if (first) {
    const v = await get(`/be/vehicle?id=${first.num}`);
    assert.equal(v.status, 200);
    console.log(`live /be/vehicle ${first.name}: ${v.json.stops.length} stops`);
  }
  const ns = await fetch(base + "/ns/departures?station=BD");
  assert.equal(ns.status, 200);
  console.log("live /ns/departures BD: 200");
}

pure();
console.log("irail pure: ok");
await local();
if (LIVE) await live(LIVE.replace(/\/$/, ""));
