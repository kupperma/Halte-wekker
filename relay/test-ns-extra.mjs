// A check of /ns/disruptions and /ns/price (ns-extra.js): locally with NS faked, or against the live relay.
// Run: node relay/test-ns-extra.mjs
// Or:  node relay/test-ns-extra.mjs https://haltewekker-relay.tsfaw1.workers.dev   (also checks the older NS routes)
import assert from "node:assert/strict";
import { nsExtra } from "./ns-extra.js";

const LIVE = process.argv[2] || null;
const cors = { "Access-Control-Allow-Origin": "*" };

async function local() {
  const asked = [];
  const answers = {};
  const fake = async (u, init) => {
    asked.push({ u, key: init?.headers?.["Ocp-Apim-Subscription-Key"] });
    for (const [prefix, a] of Object.entries(answers)) if (u.startsWith(prefix)) return new Response(a.body, { status: a.status });
    return new Response("nope", { status: 404 });
  };
  const env = { NS_KEY: "k" };
  const go = (p, e = env) => nsExtra(new URL("https://relay.test" + p), e, cors, fake);

  // other paths: not ours
  assert.equal(await go("/ns/departures?station=BD"), null);
  // bad input
  assert.equal((await go("/ns/disruptions?station=b1")).status, 400);
  assert.equal((await go("/ns/disruptions?x=1")).status, 400);
  assert.equal((await go("/ns/price?from=TB")).status, 400);
  assert.equal((await go("/ns/price?from=TB&to=BD&dateTime=<script>")).status, 400);
  // no key
  assert.equal((await go("/ns/disruptions", {})).status, 501);
  assert.equal((await go("/ns/price?from=TB&to=BD", {})).status, 501);

  // disruptions: Reisinformatie v3, else the Disruptions API
  answers["https://gateway.apiportal.ns.nl/reisinformatie-api/api/v3/disruptions"] = { status: 200, body: '[{"id":"1","type":"MAINTENANCE"}]' };
  let r = await go("/ns/disruptions?station=bd");
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("Content-Type"), "application/json");
  assert.deepEqual(await r.json(), [{ id: "1", type: "MAINTENANCE" }]);
  assert.equal(asked.at(-1).u, "https://gateway.apiportal.ns.nl/reisinformatie-api/api/v3/disruptions/station/BD?lang=en");
  assert.equal(asked.at(-1).key, "k");
  delete answers["https://gateway.apiportal.ns.nl/reisinformatie-api/api/v3/disruptions"];
  answers["https://gateway.apiportal.ns.nl/disruptions/v3"] = { status: 200, body: "[]" };
  r = await go("/ns/disruptions");
  assert.equal(r.status, 200);
  assert.equal(asked.at(-1).u, "https://gateway.apiportal.ns.nl/disruptions/v3?lang=en");

  // price: v3, else v2, else the trips' fares
  answers["https://gateway.apiportal.ns.nl/reisinformatie-api/api/v2/price"] = { status: 200, body: '{"priceOptions":[]}' };
  r = await go("/ns/price?from=tb&to=bd&dateTime=2026-11-20T08:00:00%2B01:00");
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { priceOptions: [] });
  assert.match(asked.at(-1).u, /\/api\/v2\/price\?fromStation=TB&toStation=BD&travelClass=SECOND_CLASS&travelType=single&adults=1&plannedFromTime=2026-11-20T08%3A00%3A00%2B01%3A00$/);
  delete answers["https://gateway.apiportal.ns.nl/reisinformatie-api/api/v2/price"];
  answers["https://gateway.apiportal.ns.nl/reisinformatie-api/api/v3/trips"] = {
    status: 200,
    body: JSON.stringify({ trips: [{ fares: [{ priceInCents: 600, travelClass: "SECOND_CLASS", discountType: "NO_DISCOUNT" }], productFare: { priceInCents: 600 } }] }),
  };
  r = await go("/ns/price?from=TB&to=BD");
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.source, "trips");
  assert.equal(j.fares[0].priceInCents, 600);
  assert.equal(j.productFare.priceInCents, 600);
  // NS down
  const boom = async () => { throw new Error("down"); };
  assert.equal((await nsExtra(new URL("https://relay.test/ns/disruptions"), env, cors, boom)).status, 502);
  console.log("local: ok");
}

async function live(base) {
  const get = async (p) => { const r = await fetch(base + p); return { status: r.status, text: await r.text() }; };
  for (const p of ["/ns/departures?station=BD", "/ns/trips?from=TB&to=BD", "/ns/train?num=1100&station=BD"]) {
    const r = await get(p);
    console.log(p, r.status);
    if (p.startsWith("/ns/departures")) assert.equal(r.status, 200);
  }
  const d = await get("/ns/disruptions");
  console.log("/ns/disruptions", d.status, d.text.length, "bytes", d.text.slice(0, 160).replace(/\s+/g, " "));
  assert.equal(d.status, 200);
  const list = JSON.parse(d.text);
  assert.ok(Array.isArray(list) || Array.isArray(list.payload));
  const s = await get("/ns/disruptions?station=BD");
  console.log("/ns/disruptions?station=BD", s.status, s.text.length, "bytes");
  const p = await get("/ns/price?from=TB&to=BD");
  console.log("/ns/price", p.status, p.text.slice(0, 300).replace(/\s+/g, " "));
  assert.equal(p.status, 200);
  console.log("live: ok");
}

if (LIVE) await live(LIVE.replace(/\/$/, "")); else await local();
