// Haltewekker relay (2026-11-28): trains in Belgium from iRail (https://api.irail.be, open data of NMBS/SNCB, no key;
// docs: https://docs.irail.be). Three routes, each answer trimmed to what the apps read and kept 30 s:
//
//  GET /be/liveboard?station=<name> | ?id=<UIC 88…, or BE.NMBS.0088…>
//    -> {"station":{"uic","name","lat","lon"},"departures":[{"num":"2912","type":"IC","name":"IC 2912",
//        "vehicle":"BE.NMBS.IC2912","to":"Leuven","toUic":"8833001","planned":"2026-11-28T11:33:00Z","delay":0 (s),
//        "platform":"12"|null,"platformChanged":false,"canceled":false,"left":false,"occupancy":"low"|"medium"|"high"|null}]}
//  GET /be/vehicle?id=<train number, "IC2912" or "BE.NMBS.IC2912">[&date=ddmmyy]
//    -> {"vehicle","num","type","name","stops":[{"uic","name","lat","lon","arrival","departure" (planned, ISO),
//        "arrivalDelay","departureDelay" (s),"platform","platformChanged","arrivalCanceled","departureCanceled",
//        "arrived","left"}]}
//  GET /be/composition?id=<train number or "EC9235">
//    -> {"num","segments":[{"from":{"uic","name"},"to":{"uic","name"},"units":[{"type","sub","first","second",
//        "length","toilets","bikes","prm"}]}],"cars","seats"}
//
// iRail has no GPS: its vehicle's "locationX/Y" is worked out from the timetable, so it is not passed on (the apps
// place a Belgian train by its stop times and delays, as they place any train without GPS). Errors: 400 bad_request,
// 404 not_found (iRail doesn't know it), 503 {"error":"irail_busy","retryAfter":s} after a 429, 502 no answer.
// Politeness: a descriptive User-Agent (nothing personal), one question per station or train per 30 s (the Cache
// API, else a small map in memory), 10 s of quiet after a 429 (iRail allows about 3 requests a second).

export const IRAIL = "https://api.irail.be/v1";
export const USER_AGENT = "Haltewekker-relay/1.0 (+https://github.com/kupperma/Halte-wekker)";
export const KEEP_S = 30;
export const QUIET_MS = 10000;

const NAME = /^[\p{L}0-9][\p{L}0-9 '’.()\/\-]{1,59}$/u;
const VEHICLE = /^(?:BE\.NMBS\.)?([A-Z]{0,5})(\d{1,6})$/i;

const int = (v) => {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isFinite(n) ? Math.round(n) : null;
};
const num = (v) => {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : null;
};
const yes = (v) => v === "1" || v === 1 || v === true;
const iso = (epoch) => {
  const s = int(epoch);
  return s === null || s <= 0 ? null : new Date(s * 1000).toISOString().replace(".000Z", "Z");
};

/** "BE.NMBS.008821006" (or the station's "@id" URL) → "8821006": the UIC number, without its padding. */
export function uicOf(info) {
  const raw = String((info && (info.id || info["@id"])) || "");
  const m = raw.match(/(\d{7,9})\s*$/);
  if (!m) return null;
  const d = m[1].replace(/^0+/, "");
  return d.length === 7 ? d : null;
}

const station = (info) => ({
  uic: uicOf(info),
  name: String((info && (info.standardname || info.name)) || ""),
  lat: num(info && info.locationY),
  lon: num(info && info.locationX),
});

/** "low" | "medium" | "high" | null (iRail's "unknown"). */
export function occupancy(o) {
  const n = String((o && o.name) || "").toLowerCase();
  return n === "low" || n === "medium" || n === "high" ? n : null;
}

/** A platform as iRail writes it: "?" or "" is none. */
export function platform(p) {
  const s = String(p ?? "").trim();
  return s === "" || s === "?" ? null : s;
}

/** iRail's liveboard → the departures with what the apps read. */
export function slimLiveboard(d) {
  const list = (((d || {}).departures || {}).departure) || [];
  return {
    station: station((d || {}).stationinfo),
    departures: (Array.isArray(list) ? list : []).map((x) => {
      const v = x.vehicleinfo || {};
      const to = station(x.stationinfo);
      return {
        num: String(v.number || ""),
        type: String(v.type || ""),
        name: String(v.shortname || ""),
        vehicle: String(x.vehicle || v.name || ""),
        to: String(x.station || to.name || ""),
        toUic: to.uic,
        planned: iso(x.time),
        delay: int(x.delay) ?? 0,
        platform: platform(x.platform),
        platformChanged: !!(x.platforminfo && String(x.platforminfo.normal) === "0") && platform(x.platform) !== null,
        canceled: yes(x.canceled),
        left: yes(x.left),
        occupancy: occupancy(x.occupancy),
      };
    }),
  };
}

/** iRail's vehicle → its stops with planned times, delays and platforms. */
export function slimVehicle(d) {
  const v = (d || {}).vehicleinfo || {};
  const list = (((d || {}).stops || {}).stop) || [];
  return {
    vehicle: String((d || {}).vehicle || v.name || ""),
    num: String(v.number || ""),
    type: String(v.type || ""),
    name: String(v.shortname || ""),
    stops: (Array.isArray(list) ? list : []).map((s) => {
      const at = station(s.stationinfo);
      return {
        uic: at.uic, name: String(s.station || at.name || ""), lat: at.lat, lon: at.lon,
        arrival: iso(s.scheduledArrivalTime), departure: iso(s.scheduledDepartureTime),
        arrivalDelay: int(s.arrivalDelay) ?? 0, departureDelay: int(s.departureDelay ?? s.delay) ?? 0,
        platform: platform(s.platform),
        platformChanged: !!(s.platforminfo && String(s.platforminfo.normal) === "0") && platform(s.platform) !== null,
        arrivalCanceled: yes(s.arrivalCanceled), departureCanceled: yes(s.departureCanceled ?? s.canceled),
        arrived: yes(s.arrived), left: yes(s.left),
      };
    }),
  };
}

/** iRail's composition → its units per stretch, with how many carriages and seats on the first stretch. */
export function slimComposition(d, numText = "") {
  const segs = ((((d || {}).composition || {}).segments || {}).segment) || [];
  const segments = (Array.isArray(segs) ? segs : []).map((s) => {
    const units = ((((s || {}).composition || {}).units || {}).unit) || [];
    return {
      from: { uic: uicOf(s.origin), name: String((s.origin && (s.origin.standardname || s.origin.name)) || "") },
      to: { uic: uicOf(s.destination), name: String((s.destination && (s.destination.standardname || s.destination.name)) || "") },
      units: (Array.isArray(units) ? units : []).map((u) => ({
        type: String((u.materialType && u.materialType.parent_type) || ""),
        sub: String((u.materialType && u.materialType.sub_type) || ""),
        first: (int(u.seatsFirstClass) ?? 0) + (int(u.seatsCoupeFirstClass) ?? 0),
        second: (int(u.seatsSecondClass) ?? 0) + (int(u.seatsCoupeSecondClass) ?? 0),
        length: num(u.lengthInMeter),
        toilets: yes(u.hasToilets), bikes: yes(u.hasBikeSection), prm: yes(u.hasPrmSection),
      })),
    };
  });
  const first = segments[0] ? segments[0].units : [];
  // (a locomotive has no seats: not a carriage)
  const cars = first.filter((u) => !/^(HLE|HLD|loc)/i.test(u.type) || u.first + u.second > 0).length;
  return { num: numText, segments, cars, seats: first.reduce((a, u) => a + u.first + u.second, 0) };
}

/** The question for iRail, or null when the app's isn't one. */
export function upstream(url) {
  const q = url.searchParams;
  const only = (keys) => [...q.keys()].every((k) => keys.includes(k));
  if (url.pathname === "/be/liveboard") {
    if (!only(["station", "id"])) return null;
    const id = (q.get("id") || "").trim(), name = (q.get("station") || "").trim();
    let at;
    if (id && !name) {
      const m = id.match(/^(?:BE\.NMBS\.)?0*(\d{7})$/i);
      if (!m) return null;
      at = `id=BE.NMBS.00${m[1]}`;
    } else if (name && !id) {
      if (!NAME.test(name)) return null;
      at = `station=${encodeURIComponent(name)}`;
    } else return null;
    return { kind: "liveboard", url: `${IRAIL}/liveboard/?${at}&arrdep=departure&format=json&lang=en&alerts=false` };
  }
  if (url.pathname === "/be/vehicle" || url.pathname === "/be/composition") {
    if (!only(url.pathname === "/be/vehicle" ? ["id", "date"] : ["id"])) return null;
    const m = (q.get("id") || "").trim().match(VEHICLE);
    const date = (q.get("date") || "").trim();
    if (!m || (date && !/^\d{6}$/.test(date))) return null;
    const id = (m[1] || "").toUpperCase() + m[2];
    if (url.pathname === "/be/vehicle")
      return { kind: "vehicle", url: `${IRAIL}/vehicle/?id=BE.NMBS.${id}${date ? `&date=${date}` : ""}&format=json&lang=en&alerts=false` };
    return { kind: "composition", num: m[2], url: `${IRAIL}/composition/?id=${id}&format=json` };
  }
  return null;
}

const reply = (o, status, cors, maxAge) =>
  new Response(typeof o === "string" ? o : JSON.stringify(o), {
    status,
    headers: { ...cors, "Content-Type": "application/json", "Cache-Control": maxAge ? `max-age=${maxAge}` : "no-store" },
  });

const kept = new Map();       // upstream URL → {at, status, body}: per isolate, when the Cache API isn't there
let quietUntil = 0;

/** For the tests: forget what is kept. */
export function forget() { kept.clear(); quietUntil = 0; }

/**
 * /be/*: checks the question, asks iRail (or takes the answer kept for 30 s), trims it. `opts.fetchImpl`, `opts.cache`
 * (a Cache API cache; null: none) and `opts.now` for the tests.
 */
export async function be(url, cors, opts = {}) {
  const fetchImpl = opts.fetchImpl || ((u, i) => fetch(u, i));
  const now = opts.now || (() => Date.now());
  const cache = opts.cache !== undefined ? opts.cache : (typeof caches !== "undefined" ? caches.default : null);
  const up = upstream(url);
  if (!up) return reply({ error: "bad_request" }, 400, cors);
  const t = now();
  const mem = kept.get(up.url);
  if (mem && t - mem.at < KEEP_S * 1000) return reply(mem.body, mem.status, cors, mem.status === 200 ? KEEP_S : 0);
  const key = new Request(up.url);
  if (cache) {
    try {
      const hit = await cache.match(key);
      if (hit) return reply(await hit.text(), hit.status, cors, KEEP_S);
    } catch (e) { /* no cache: ask */ }
  }
  if (t < quietUntil) return reply({ error: "irail_busy", retryAfter: Math.ceil((quietUntil - t) / 1000) }, 503, cors);
  let r;
  try {
    r = await fetchImpl(up.url, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" } });
  } catch (e) {
    return reply({ error: "no_answer" }, 502, cors);
  }
  if (r.status === 429) {
    quietUntil = t + QUIET_MS;
    return reply({ error: "irail_busy", retryAfter: QUIET_MS / 1000 }, 503, cors);
  }
  let status = 200, body;
  if (r.status === 404) { status = 404; body = JSON.stringify({ error: "not_found" }); }
  else if (r.status !== 200) return reply({ error: "irail_" + r.status }, 502, cors);
  else {
    let d;
    try { d = await r.json(); } catch (e) { return reply({ error: "not_json" }, 502, cors); }
    const slim = up.kind === "liveboard" ? slimLiveboard(d) : up.kind === "vehicle" ? slimVehicle(d) : slimComposition(d, up.num);
    body = JSON.stringify(slim);
  }
  if (kept.size > 300) kept.clear();
  kept.set(up.url, { at: t, status, body });
  if (cache) {
    try {
      await cache.put(key, new Response(body, { status, headers: { "Content-Type": "application/json", "Cache-Control": `max-age=${KEEP_S}` } }));
    } catch (e) { /* kept in memory */ }
  }
  return reply(body, status, cors, status === 200 ? KEEP_S : 0);
}
