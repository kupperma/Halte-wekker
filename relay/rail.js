// Haltewekker relay (2026-11-27): which side you get out of the train, from OpenStreetMap.
//
//  GET /rail/v1/side?station=<NS code or name>&track=<4|4a|…>&from=<lat,lon of the stop before>&at=<lat,lon of the station>
//    -> 200 {"side":"left"|"right"|"both"|"unknown","confidence":"high"|"low"|null,"platformRef":"4a"|null[,"why"]}
//       400 bad_request · 503 {"side":"unknown","why":"osm_busy","retryAfter":s} while Overpass can't be asked
//  "left"/"right": where the platform is, looking the way the train goes. Only the station and its track are sent by
//  the app, with the stop before and the station's place (both public stations): never where you are.
//
// How (`sideOf`, pure, tested in test-rail.mjs on trimmed OSM data of 's-Hertogenbosch, Eindhoven, Breda, Tilburg):
//  1. The platforms of that track: railway=platform / platform_edge / public_transport=platform whose ref, local_ref
//     or railway:track_ref (a ";" list) holds the track ("4a" also takes a plain "4"; "4" takes "4a" and "4b"; an exact
//     match wins). In the Netherlands each side of an island platform is its own area with its own ref.
//  2. For each: its centre, and the nearest railway=rail to it (a rail with railway:track_ref = the track wins; no
//     crossovers). Further than 25 m: not this platform's track.
//  3. The way the train goes: the stop before → the station, along that rail's direction there.
//  4. The side: the sign of (direction) × (platform centre − nearest rail point): positive = left.
//  A platform with another rail about as near on its other side (one area for both sides of an island) can't say which
//  track is which: skipped, unless a platform of another track lies next to it on that side (the island's other half).
//  A bundled station may say where a line really comes in from ("approach": Boxtel from Tilburg comes in from the
//  south-east), used instead of the stop before. Platforms on both sides: "both". Nothing found or nothing sure: "unknown" (the app shows
//  nothing). "low": the line bends between the two stops, or the match was loose.
//
// OSM data, in this order: what the station's Durable Object ("Rail", one per station) keeps; else the bundled seed
// (rail-seed/: the stations on the Breda ⇄ Tilburg ⇄ 's-Hertogenbosch ⇄ Eindhoven lines, trimmed the same way, so
// they never wait on Overpass); else one Overpass request (the instances raced, each a little after the one before
// or as soon as it fails; a descriptive User-Agent, [timeout:15], nothing personal). What is found is trimmed to the
// platforms and rails in a box 400 m around the station and kept 30 days in the Durable Object; a busy Overpass
// (429/5xx/no answer) is asked again only after 10 minutes (30 after a 429). Map data © OpenStreetMap contributors, ODbL.

import { SEED } from "./rail-seed/index.js";

export const OVERPASS = "https://overpass-api.de/api/interpreter";
/** Raced for a station's miss: each starts STAGGER_MS after the one before, or at once when that one fails. */
export const OVERPASS_ALL = [OVERPASS, "https://maps.mail.ru/osm/tools/overpass/api/interpreter", "https://overpass.private.coffee/api/interpreter"];
export const USER_AGENT = "Haltewekker-relay/1.0 (+https://github.com/kupperma/Halte-wekker)";
export const RADIUS = 400;                      // m around the station
export const KEEP_MS = 30 * 24 * 3600 * 1000;   // a station's OSM data
export const EMPTY_KEEP_MS = 7 * 24 * 3600 * 1000;   // a station where OSM had nothing
export const RETRY_MS = 10 * 60 * 1000;          // after a busy Overpass
export const STAGGER_MS = 1500;                  // between the raced Overpass instances
export const ASK_MS = 18000;                     // one Overpass instance at most
export const SEED_NEAR = 800;                    // m: a bundled station this near the asked place is that station
const NEAR_RAIL = 25;                            // m: a platform this far from its track at most
const OTHER_SIDE = 1.6;                          // another rail this much as near on the other side: can't tell

const R_LAT = 110540, R_LON = 111320;

/** "Spoor 4a", " 4A " → "4a". */
export function normTrack(s) {
  return String(s ?? "").trim().toLowerCase().replace(/^(spoor|track|platform|perron)\s*/, "").replace(/\s+/g, "");
}

/** How a platform's ref list matches the track: 2 exact, 1 loose (number only), 0 not. */
export function refMatch(refs, track) {
  const t = normTrack(track);
  const tn = (t.match(/^\d+/) || [""])[0];
  let best = 0;
  for (const raw of String(refs ?? "").split(/[;,/]/)) {
    const r = normTrack(raw);
    if (!r) continue;
    if (r === t) return 2;
    const rn = (r.match(/^\d+/) || [""])[0];
    if (tn && rn === tn && (r === rn || t === tn)) best = 1;
  }
  return best;
}

const refsOf = (tags) => {
  const list = [tags.ref, tags.local_ref, tags["railway:track_ref"]].filter((x) => typeof x === "string" && x.trim());
  if (!list.length && typeof tags.name === "string") {
    const m = tags.name.match(/^\s*(?:spoor|track)\s+([0-9]{1,2}[a-z]?(?:\s*[;,/]\s*[0-9]{1,2}[a-z]?)*)\s*$/i);
    if (m) list.push(m[1]);
  }
  return [...new Set(list.join(";").split(";").map((x) => x.trim()).filter(Boolean))].join(";");
};

const isPlatform = (t) =>
  t.railway === "platform" || t.railway === "platform_edge" ||
  (t.public_transport === "platform" && (t.train === "yes" || t.railway === "platform"));

/** Overpass JSON (`out tags geom`) → the platforms and rails it has, with only what `sideOf` reads. */
export function trim(json) {
  const out = { platforms: [], rails: [] };
  for (const e of (json && Array.isArray(json.elements) ? json.elements : [])) {
    const t = e && e.tags ? e.tags : {};
    let pts = [];
    if (e.type === "way" && Array.isArray(e.geometry)) pts = e.geometry;
    else if (e.type === "node" && typeof e.lat === "number") pts = [{ lat: e.lat, lon: e.lon }];
    else if (e.type === "relation" && Array.isArray(e.members))
      for (const m of e.members) if (m.role !== "inner" && Array.isArray(m.geometry)) pts = pts.concat(m.geometry);
    pts = pts.filter((p) => p && typeof p.lat === "number" && typeof p.lon === "number")
      .map((p) => [Math.round(p.lat * 1e6) / 1e6, Math.round(p.lon * 1e6) / 1e6]);
    if (!pts.length) continue;
    if (t.railway === "rail" && pts.length >= 2) {
      if (t.service === "crossover") continue;
      const r = { pts };
      if (t["railway:track_ref"]) r.track = String(t["railway:track_ref"]);
      out.rails.push(r);
    } else if (isPlatform(t)) {
      const refs = refsOf(t);
      if (!refs) continue;
      out.platforms.push({ refs, pts, edge: t.railway === "platform_edge" });
    }
  }
  return out;
}

/** "51.69,5.29" → {lat, lon}; null when it isn't a place. */
export function parsePoint(s) {
  const m = String(s ?? "").match(/^\s*(-?\d{1,2}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*$/);
  if (!m) return null;
  const lat = Number(m[1]), lon = Number(m[2]);
  return Math.abs(lat) <= 90 && Math.abs(lon) <= 180 ? { lat, lon } : null;
}

function project(origin) {
  const k = Math.cos((origin.lat * Math.PI) / 180);
  return ([lat, lon]) => [(lon - origin.lon) * R_LON * k, (lat - origin.lat) * R_LAT];
}

/** The centre of a ring (area weighted), else of its points. */
function centre(xy) {
  let pts = xy;
  if (pts.length > 2 && pts[0][0] === pts.at(-1)[0] && pts[0][1] === pts.at(-1)[1]) pts = pts.slice(0, -1);
  if (pts.length >= 3) {
    let a = 0, cx = 0, cy = 0;
    for (let i = 0; i < pts.length; i++) {
      const [x0, y0] = pts[i], [x1, y1] = pts[(i + 1) % pts.length];
      const c = x0 * y1 - x1 * y0;
      a += c; cx += (x0 + x1) * c; cy += (y0 + y1) * c;
    }
    if (Math.abs(a) > 1) return [cx / (3 * a), cy / (3 * a)];
  }
  if (pts.length === 2 || (xy.length >= 2 && pts.length < 3)) {
    // a line (a platform edge): its middle along its length
    let total = 0;
    const seg = [];
    for (let i = 1; i < xy.length; i++) { const l = Math.hypot(xy[i][0] - xy[i - 1][0], xy[i][1] - xy[i - 1][1]); seg.push(l); total += l; }
    let half = total / 2;
    for (let i = 1; i < xy.length; i++) {
      if (half <= seg[i - 1] && seg[i - 1] > 0) {
        const f = half / seg[i - 1];
        return [xy[i - 1][0] + f * (xy[i][0] - xy[i - 1][0]), xy[i - 1][1] + f * (xy[i][1] - xy[i - 1][1])];
      }
      half -= seg[i - 1];
    }
  }
  const n = pts.length;
  return [pts.reduce((s, p) => s + p[0], 0) / n, pts.reduce((s, p) => s + p[1], 0) / n];
}

/** The nearest point of a polyline to p: {d, at, dir (unit)}. */
function nearest(line, p) {
  let best = null;
  for (let i = 1; i < line.length; i++) {
    const [ax, ay] = line[i - 1], [bx, by] = line[i];
    const dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
    if (l2 < 1e-6) continue;
    const f = Math.max(0, Math.min(1, ((p[0] - ax) * dx + (p[1] - ay) * dy) / l2));
    const qx = ax + f * dx, qy = ay + f * dy;
    const d = Math.hypot(p[0] - qx, p[1] - qy);
    if (!best || d < best.d) { const l = Math.sqrt(l2); best = { d, at: [qx, qy], dir: [dx / l, dy / l] }; }
  }
  return best;
}

const cross = (a, b) => a[0] * b[1] - a[1] * b[0];

/**
 * Which side the platform of `track` is on, for a train from `from` to `at` ({lat, lon} each), in trimmed data.
 * -> {side, confidence, platformRef, why?}
 */
export function sideOf(data, track, from, at) {
  const none = (why) => ({ side: "unknown", confidence: null, platformRef: null, why });
  const t = normTrack(track);
  if (!data || !t) return none("no_data");
  const xy = project(at);
  // a line that comes in from another side than the stop before is (seeded stations: a point on the line instead)
  for (const a of data.approach || []) {
    const [ax, ay] = xy(a.from), [fx, fy] = xy([from.lat, from.lon]);
    if (Math.hypot(fx - ax, fy - ay) <= a.within) { from = { lat: a.via[0], lon: a.via[1] }; break; }
  }
  const f = xy([from.lat, from.lon]);                 // the station is (0, 0)
  const travel = Math.hypot(f[0], f[1]);
  if (travel < 300) return none("no_direction");
  const v = [-f[0] / travel, -f[1] / travel];          // the way the train goes, as the crow flies
  const rails = data.rails.map((r) => ({ track: r.track ? normTrack(r.track) : null, line: r.pts.map(xy) }));
  const own = rails.filter((r) => r.track && refMatch(r.track, t) === 2);
  let plats = data.platforms.map((p) => ({ ...p, m: refMatch(p.refs, t) })).filter((p) => p.m > 0);
  if (plats.some((p) => p.m === 2)) plats = plats.filter((p) => p.m === 2);
  if (!plats.length) return none("no_platform");
  // the other half of an island: a platform of another track, close by, nearer the other rail than this one is
  const others = data.platforms.filter((p) => refMatch(p.refs, t) === 0).map((p) => centre(p.pts.map(xy)));
  const otherHalf = (c, near, other) => others.some((o) => {
    if (Math.hypot(o[0] - c[0], o[1] - c[1]) > 20) return false;
    const toOther = nearest(other.line, o), toNear = nearest(near.line, o);
    return toOther && toNear && toOther.d < other.d && toNear.d > near.d;
  });

  const sides = [];
  let loose = plats[0].m < 2, skipped = 0, ref = null;
  for (const p of plats) {
    const c = centre(p.pts.map(xy));
    if (Math.hypot(c[0], c[1]) > RADIUS + 300) continue;
    const pick = (list) => list.map((r) => { const n = nearest(r.line, c); return n && { ...n, line: r.line }; })
      .filter(Boolean).sort((a, b) => a.d - b.d);
    const mine = own.length ? pick(own)[0] : null;
    const all = pick(rails);
    const near = mine || all[0];
    if (!near || near.d > NEAR_RAIL) { skipped++; continue; }
    const s = Math.sign(cross(near.dir, [c[0] - near.at[0], c[1] - near.at[1]]));
    if (s === 0) { skipped++; continue; }
    if (!mine && !p.edge) {
      // one area for both sides of an island (or a platform between two tracks): which is this track can't be told
      const other = all.find((o) => Math.sign(cross(near.dir, [c[0] - o.at[0], c[1] - o.at[1]])) === -s);
      if (other && other.d < near.d * OTHER_SIDE && other.d <= NEAR_RAIL && !otherHalf(c, near, other)) { skipped++; continue; }
    }
    const along = near.dir[0] * v[0] + near.dir[1] * v[1];
    if (Math.abs(along) < 0.2) { skipped++; continue; }
    const side = s * Math.sign(along) > 0 ? "left" : "right";
    sides.push({ side, sure: Math.abs(along) >= 0.5 && near.d <= 15, ref: normTrack(p.refs.split(/[;,/]/).find((r) => refMatch(r, t)) || p.refs) });
    if (!ref) ref = sides.at(-1).ref;
  }
  if (!sides.length) return none(skipped ? "ambiguous" : "no_platform");
  const set = new Set(sides.map((x) => x.side));
  const side = set.size > 1 ? "both" : sides[0].side;
  const sure = sides.every((x) => x.sure) && !loose;
  const refs = [...new Set(sides.map((x) => x.ref))];
  return { side, confidence: sure ? "high" : "low", platformRef: refs.length === 1 ? refs[0] : t };
}

/** The Overpass question for a station at {lat, lon}: a box 400 m around it (a box is what Overpass finds fast), only
 *  the ways `trim` keeps, their geometry clipped to a slightly larger box. */
export function overpassQuery(at) {
  const box = (r) => {
    const dLat = r / R_LAT, dLon = r / (R_LON * Math.cos((at.lat * Math.PI) / 180));
    return `${(at.lat - dLat).toFixed(5)},${(at.lon - dLon).toFixed(5)},${(at.lat + dLat).toFixed(5)},${(at.lon + dLon).toFixed(5)}`;
  };
  return `[out:json][timeout:15][bbox:${box(RADIUS)}];(` +
    `way["railway"~"^(rail|platform|platform_edge)$"];relation["railway"="platform"];` +
    `way["public_transport"="platform"]["train"="yes"];);out tags geom(${box(RADIUS + 200)});`;
}

/** The bundled station nearest to `at` (within SEED_NEAR), or null. */
export function seedFor(at, seed = SEED) {
  const xy = project(at);
  let best = null, bd = SEED_NEAR;
  for (const st of seed) {
    const [x, y] = xy(st.at);
    const d = Math.hypot(x, y);
    if (d <= bd) { best = st; bd = d; }
  }
  return best ? { platforms: best.platforms, rails: best.rails, ...(best.approach ? { approach: best.approach } : {}) } : null;
}

const STATION = /^[\p{L}0-9][\p{L}0-9 '’.()\/\-]{0,39}$/u;     // (2026-11-28: accents and "/", Belgian names)
const TRACK = /^[0-9]{1,2}[a-zA-Z]?$/;

const reply = (o, status, cors, maxAge) =>
  new Response(JSON.stringify(o), {
    status,
    headers: { ...cors, "Content-Type": "application/json", "Cache-Control": maxAge ? `max-age=${maxAge}` : "no-store" },
  });

/** The station's key for its Durable Object: "st:BD@51.60,4.78" (a name lowercased). */
export function stationKey(station, at) {
  const s = /^[A-Z]{2,5}$/i.test(station) && !/\s/.test(station) ? station.toUpperCase() : station.toLowerCase();
  return `st:${s}@${at.lat.toFixed(2)},${at.lon.toFixed(2)}`;
}

/** /rail/v1/side, in the Worker: checks the question, gets the station's OSM data from its Durable Object. */
export async function rail(request, env, url, cors) {
  if (url.pathname !== "/rail/v1/side") return reply({ error: "not_found" }, 404, cors);
  for (const k of url.searchParams.keys()) if (!["station", "track", "from", "at"].includes(k)) return reply({ error: "bad_request" }, 400, cors);
  const station = (url.searchParams.get("station") || "").trim();
  const track = (url.searchParams.get("track") || "").trim();
  const from = parsePoint(url.searchParams.get("from"));
  const at = parsePoint(url.searchParams.get("at"));
  if (!STATION.test(station) || !TRACK.test(normTrack(track)) || !from || !at) return reply({ error: "bad_request" }, 400, cors);
  if (!env.RAIL) return reply({ side: "unknown", confidence: null, platformRef: null, why: "not_configured" }, 503, cors);
  const key = stationKey(station, at);
  const stub = env.RAIL.get(env.RAIL.idFromName(key));
  const r = await stub.fetch("https://rail.internal/data", { method: "POST", body: JSON.stringify({ lat: at.lat, lon: at.lon }) });
  const got = await r.json();
  if (!got.data) return reply({ side: "unknown", confidence: null, platformRef: null, why: "osm_busy", retryAfter: got.retryAfter || 600, osm: got.osm || null }, 503, cors);
  const ans = sideOf(got.data, track, from, at);
  return reply(ans, 200, cors, 86400);
}

/** One station's OSM data, asked once and kept (the Durable Object "Rail"). `fetchImpl`, `now`, `seed` and `stagger`
 *  for the tests. */
export class RailCore {
  constructor(ctx, env, fetchImpl = (u, i) => fetch(u, i), now = () => Date.now(), seed = SEED, stagger = STAGGER_MS) {
    this.store = ctx.storage;
    this.fetchImpl = fetchImpl;
    this.now = now;
    this.seed = seed;
    this.stagger = stagger;
    this.pending = null;
  }

  async fetch(request) {
    try {
      const body = await request.json();
      const at = { lat: Number(body.lat), lon: Number(body.lon) };
      if (!Number.isFinite(at.lat) || !Number.isFinite(at.lon)) return reply({ error: "bad_request" }, 400, {});
      const kept = await this.store.get("d");
      const t = this.now();
      const seeded = seedFor(at, this.seed);
      // what is kept; but an empty answer kept from Overpass doesn't hide a bundled station
      if (kept && kept.data && kept.exp > t && (kept.data.platforms.length || !seeded)) return reply({ data: kept.data }, 200, {});
      if (seeded) {
        await this.store.put("d", { data: seeded, exp: t + KEEP_MS, from: "seed" });
        return reply({ data: seeded }, 200, {});
      }
      if (kept && kept.retryAt > t) return reply({ retryAfter: Math.ceil((kept.retryAt - t) / 1000), osm: kept.osm }, 200, {});
      if (!this.pending) this.pending = this.ask(at).finally(() => { this.pending = null; });
      return reply(await this.pending, 200, {});
    } catch (e) {
      return reply({ error: "relay_error" }, 500, {});
    }
  }

  /** One Overpass instance: {data} (trimmed), or {osm} why there was none. `signal` stops it once another answered. */
  async askOne(endpoint, at, signal) {
    const ctl = new AbortController();
    const stop = () => ctl.abort();
    signal.addEventListener("abort", stop);
    const timer = setTimeout(stop, ASK_MS);
    const t0 = Date.now();
    try {
      const r = await this.fetchImpl(`${endpoint}?data=${encodeURIComponent(overpassQuery(at))}`, {
        method: "GET", signal: ctl.signal, headers: { "User-Agent": USER_AGENT, Accept: "application/json" },
      });
      if (r.status !== 200) return { osm: String(r.status) };
      const json = await r.json();
      // a query that ran out of time still answers 200, with a "remark" and part of the data
      if (!json || !Array.isArray(json.elements) || /error|timed out/i.test(String(json.remark || ""))) return { osm: "partial" };
      return { data: trim(json), osm: "200" };
    } catch (e) {
      if (signal.aborted) return { osm: "-" };
      return { osm: (e && e.name === "AbortError" ? "timeout" : e instanceof SyntaxError ? "not_json" : "no_answer") + "@" + (Date.now() - t0) };
    } finally { clearTimeout(timer); signal.removeEventListener("abort", stop); }
  }

  /** All instances raced: the first good answer wins, the others are stopped. */
  async race(at) {
    const all = new AbortController();
    const seen = OVERPASS_ALL.map(() => "-");
    let started = 0;
    return await new Promise((resolve) => {
      let done = false, left = OVERPASS_ALL.length, timer = null;
      const next = () => {
        if (done || started >= OVERPASS_ALL.length) return;
        const i = started++;
        clearTimeout(timer);
        if (started < OVERPASS_ALL.length) timer = setTimeout(next, this.stagger);
        this.askOne(OVERPASS_ALL[i], at, all.signal).then((one) => {
          if (done) return;
          seen[i] = one.osm;
          if (one.data) { done = true; clearTimeout(timer); all.abort(); resolve({ data: one.data, osm: seen.join(",") }); return; }
          if (--left === 0) { done = true; resolve({ osm: seen.join(",") }); return; }
          next();    // this one can't answer: the next at once
        });
      };
      next();
    });
  }

  async ask(at) {
    const t = this.now();
    const got = await this.race(at);
    if (!got.data) {
      const wait = got.osm.includes("429") ? 3 * RETRY_MS : RETRY_MS;
      await this.store.put("d", { retryAt: t + wait, osm: got.osm });
      return { retryAfter: Math.ceil(wait / 1000), osm: got.osm };
    }
    const data = got.data;
    const empty = !data.platforms.length || !data.rails.length;
    await this.store.put("d", { data, exp: t + (empty ? EMPTY_KEEP_MS : KEEP_MS) });
    return { data };
  }
}
