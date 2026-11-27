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
//  track is which: skipped. Platforms on both sides: "both". Nothing found or nothing sure: "unknown" (the app shows
//  nothing). "low": the line bends between the two stops, or the match was loose.
//
// OSM data: one Overpass request per station on a miss (a second instance only when the first can't answer; a descriptive User-Agent, 25 s, nothing personal), trimmed to
// the platforms and rails within 400 m and kept 30 days in a Durable Object ("Rail", one per station); a busy Overpass
// (429/504/no answer) is asked again only after 10 minutes. Map data © OpenStreetMap contributors, ODbL.

export const OVERPASS = "https://overpass-api.de/api/interpreter";
export const OVERPASS_2 = "https://overpass.private.coffee/api/interpreter";   // only when the first can't answer
export const USER_AGENT = "Haltewekker-relay/1.0 (+https://github.com/kupperma/Halte-wekker)";
export const RADIUS = 400;                      // m around the station
export const KEEP_MS = 30 * 24 * 3600 * 1000;   // a station's OSM data
export const EMPTY_KEEP_MS = 7 * 24 * 3600 * 1000;   // a station where OSM had nothing
export const RETRY_MS = 10 * 60 * 1000;          // after a busy Overpass
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
  const f = xy([from.lat, from.lon]);                 // the station is (0, 0)
  const travel = Math.hypot(f[0], f[1]);
  if (travel < 300) return none("no_direction");
  const v = [-f[0] / travel, -f[1] / travel];          // the way the train goes, as the crow flies
  const rails = data.rails.map((r) => ({ track: r.track ? normTrack(r.track) : null, line: r.pts.map(xy) }));
  const own = rails.filter((r) => r.track && refMatch(r.track, t) === 2);
  let plats = data.platforms.map((p) => ({ ...p, m: refMatch(p.refs, t) })).filter((p) => p.m > 0);
  if (plats.some((p) => p.m === 2)) plats = plats.filter((p) => p.m === 2);
  if (!plats.length) return none("no_platform");

  const sides = [];
  let loose = plats[0].m < 2, skipped = 0, ref = null;
  for (const p of plats) {
    const c = centre(p.pts.map(xy));
    if (Math.hypot(c[0], c[1]) > RADIUS + 300) continue;
    const pick = (list) => list.map((r) => nearest(r.line, c)).filter(Boolean).sort((a, b) => a.d - b.d);
    const mine = own.length ? pick(own)[0] : null;
    const all = pick(rails);
    const near = mine || all[0];
    if (!near || near.d > NEAR_RAIL) { skipped++; continue; }
    const s = Math.sign(cross(near.dir, [c[0] - near.at[0], c[1] - near.at[1]]));
    if (s === 0) { skipped++; continue; }
    if (!mine && !p.edge) {
      // one area for both sides of an island (or a platform between two tracks): which is this track can't be told
      const other = all.find((o) => Math.sign(cross(near.dir, [c[0] - o.at[0], c[1] - o.at[1]])) === -s);
      if (other && other.d < near.d * OTHER_SIDE && other.d <= NEAR_RAIL) { skipped++; continue; }
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

/** The Overpass question for a station at {lat, lon}. */
export function overpassQuery(at) {
  const a = `(around:${RADIUS},${at.lat.toFixed(6)},${at.lon.toFixed(6)})`;
  return `[out:json][timeout:25];(` +
    `way["railway"~"^(platform|platform_edge)$"]${a};relation["railway"="platform"]${a};` +
    `way["public_transport"="platform"]["train"="yes"]${a};node["railway"="platform"]${a};` +
    `way["railway"="rail"]${a};);out tags geom;`;
}

const STATION = /^[A-Za-z0-9][A-Za-z0-9 '’.()\-]{0,39}$/;
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

/** One station's OSM data, asked once and kept (the Durable Object "Rail"). `fetchImpl` and `now` for the tests. */
export class RailCore {
  constructor(ctx, env, fetchImpl = (u, i) => fetch(u, i), now = () => Date.now()) {
    this.store = ctx.storage;
    this.fetchImpl = fetchImpl;
    this.now = now;
    this.pending = null;
  }

  async fetch(request) {
    try {
      const body = await request.json();
      const at = { lat: Number(body.lat), lon: Number(body.lon) };
      if (!Number.isFinite(at.lat) || !Number.isFinite(at.lon)) return reply({ error: "bad_request" }, 400, {});
      const kept = await this.store.get("d");
      const t = this.now();
      if (kept && kept.data && kept.exp > t) return reply({ data: kept.data }, 200, {});
      if (kept && kept.retryAt > t) return reply({ retryAfter: Math.ceil((kept.retryAt - t) / 1000), osm: kept.osm }, 200, {});
      if (!this.pending) this.pending = this.ask(at).finally(() => { this.pending = null; });
      return reply(await this.pending, 200, {});
    } catch (e) {
      return reply({ error: "relay_error" }, 500, {});
    }
  }

  /** One Overpass instance: its answer, or why there was none. */
  async askOne(endpoint, at) {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 25000);
    try {
      const r = await this.fetchImpl(endpoint, {
        method: "POST", signal: ctl.signal,
        headers: { "User-Agent": USER_AGENT, "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
        body: "data=" + encodeURIComponent(overpassQuery(at)),
      });
      return { r, osm: String(r.status) };
    } catch (e) {
      return { r: null, osm: e && e.name === "AbortError" ? "timeout" : "no_answer" };
    } finally { clearTimeout(timer); }
  }

  async ask(at) {
    const t = this.now();
    // the main instance; only when it can't answer, once the other one
    let { r, osm } = await this.askOne(OVERPASS, at);
    if (!r || r.status !== 200) {
      const second = await this.askOne(OVERPASS_2, at);
      osm += "," + second.osm;
      if (second.r && second.r.status === 200) r = second.r;
    }
    if (!r || r.status !== 200) {
      const wait = osm.includes("429") ? 3 * RETRY_MS : RETRY_MS;
      await this.store.put("d", { retryAt: t + wait, osm });
      return { retryAfter: Math.ceil(wait / 1000), osm };
    }
    let data;
    try { data = trim(await r.json()); } catch (e) {
      await this.store.put("d", { retryAt: t + RETRY_MS });
      return { retryAfter: RETRY_MS / 1000 };
    }
    const empty = !data.platforms.length || !data.rails.length;
    await this.store.put("d", { data, exp: t + (empty ? EMPTY_KEEP_MS : KEEP_MS) });
    return { data };
  }
}
