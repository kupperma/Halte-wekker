// Haltewekker relay (0.36): two more NS passthroughs with the relay's NS key, next to the ones in worker.js.
//  /ns/disruptions[?station=BD][&lang=en]   NS disruptions, calamities and planned engineering works (Reisinformatie
//                                           API v3; the separate Disruptions API when that one isn't there). The
//                                           answer is NS's own list, passed on as it is.
//  /ns/disruptions?stations=TB,BD,HT        The app's way (some 650 KB is the whole country): only the disruptions and
//                                           works on a stretch with one of these stations, slimmed to what the app
//                                           reads (id, type, title, start, end, isActive, timespans, sections).
//  /ns/price?from=TB&to=BD[&dateTime=…][&travelClass=2]
//                                           What a single journey costs: NS's price endpoint (v3, then v2). When neither
//                                           answers, the fares NS puts on its first trip for that journey, as
//                                           {"source":"trips","fares":[…],"productFare":{…}} (the same fare objects:
//                                           priceInCents, travelClass, discountType).
//  /ns/ovfiets?station=BD[&raw=1]          (0.37) How many OV-fiets (NS rental bikes) are left at a station: NS's
//                                           Places API (v2 ovfiets, then v2 places of type ovfiets), slimmed to
//                                           {"station":"BD","locations":[{"name","code","bikes","lat","lon","open"}]}
//                                           (bikes: null when NS doesn't say). raw=1 passes NS's answer on as it is.
// Nothing about where you are is sent: station codes only. Returns null for any other path.

const GW = "https://gateway.apiportal.ns.nl";
const STATION = /^[A-Z]{2,5}$/;
const WHEN = /^[0-9T:+\-.Z]{10,30}$/;

function json(text, status, cors, maxAge) {
  return new Response(text, {
    status,
    headers: { ...cors, "Content-Type": "application/json", "Cache-Control": `max-age=${maxAge}` },
  });
}

const slimStations = (sec) => ({
  stations: (((sec || {}).stations) || []).map((x) => ({ stationCode: x.stationCode, name: x.name })),
  direction: (sec || {}).direction,
});

/** Only the disruptions and works on a stretch with one of `codes`, with only what the app reads. */
export function slimDisruptions(list, codes) {
  const all = Array.isArray(list) ? list : (list && Array.isArray(list.payload) ? list.payload : []);
  const out = [];
  for (const d of all) {
    const secs = (d && d.publicationSections) || [];
    const hit = secs.some((p) => [p.section, (p.consequence || {}).section].some((s) => ((s || {}).stations || []).some((x) => codes.has(x.stationCode))));
    if (!hit) continue;
    out.push({
      id: d.id, type: d.type, title: d.title, isActive: d.isActive, start: d.start, end: d.end,
      timespans: (d.timespans || []).map((t) => ({
        start: t.start, end: t.end, situation: t.situation, cause: t.cause, alternativeTransport: t.alternativeTransport,
        additionalTravelTime: t.additionalTravelTime,
      })),
      publicationSections: secs.map((p) => ({
        section: slimStations(p.section),
        consequence: p.consequence ? { section: slimStations(p.consequence.section), description: p.consequence.description, level: p.consequence.level } : null,
        sectionType: p.sectionType,
      })),
    });
  }
  return out;
}

const toNum = (v) => {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : null;
};

/** The OV-fiets places in NS's Places answer (any depth: `payload[].locations[]`), each with how many bikes are left. */
export function slimOvfiets(answer, station) {
  const out = [];
  const seen = new Set();
  const walk = (x, depth) => {
    if (!x || typeof x !== "object" || depth > 6) return;
    if (Array.isArray(x)) { for (const y of x) walk(y, depth + 1); return; }
    const extra = x.extra && typeof x.extra === "object" ? x.extra : {};
    const has = "rentalBikes" in extra || "rentalBikes" in x;
    const lat = toNum(x.lat), lon = toNum(x.lng ?? x.lon);
    if (has || (lat !== null && lon !== null && typeof x.name === "string" && (x.stationCode || extra.locationCode))) {
      const code = String(extra.locationCode || x.locationCode || x.id || x.name || "");
      if (!seen.has(code)) {
        seen.add(code);
        const sc = typeof x.stationCode === "string" ? x.stationCode.toUpperCase() : null;
        if (!sc || sc === station) {
          out.push({
            name: typeof x.name === "string" ? x.name : "", code,
            bikes: toNum(extra.rentalBikes ?? x.rentalBikes), lat, lon,
            open: typeof x.open === "string" ? x.open : null,
          });
        }
      }
      return;
    }
    for (const k of Object.keys(x)) if (k !== "links") walk(x[k], depth + 1);
  };
  walk(answer, 0);
  return { station, locations: out };
}

export async function nsExtra(url, env, cors, fetchImpl = fetch) {
  const NS_KEY = env.NS_KEY || env["NS-KEY"];
  const headers = { "Ocp-Apim-Subscription-Key": NS_KEY || "" };

  if (url.pathname === "/ns/disruptions") {
    const station = (url.searchParams.get("station") || "").toUpperCase();
    const lang = (url.searchParams.get("lang") || "en").toLowerCase();
    const many = url.searchParams.has("stations")
      ? (url.searchParams.get("stations") || "").toUpperCase().split(",").filter((x) => x) : null;
    for (const k of url.searchParams.keys()) if (k !== "station" && k !== "lang" && k !== "stations") return new Response("Bad request", { status: 400, headers: cors });
    if ((station && !STATION.test(station)) || !/^(en|nl)$/.test(lang)) return new Response("Bad request", { status: 400, headers: cors });
    if (many && (station || many.length === 0 || many.length > 40 || !many.every((c) => STATION.test(c))))
      return new Response("Bad request", { status: 400, headers: cors });
    if (!NS_KEY) return new Response("No NS key set", { status: 501, headers: cors });
    try {
      const tail = (station ? `/station/${station}` : "") + `?lang=${lang}`;
      let r = await fetchImpl(`${GW}/reisinformatie-api/api/v3/disruptions${tail}`, { headers });
      if (r.status === 404) r = await fetchImpl(`${GW}/disruptions/v3${tail}`, { headers });
      if (!many || r.status !== 200) return json(await r.text(), r.status, cors, 300);
      return json(JSON.stringify(slimDisruptions(await r.json(), new Set(many))), 200, cors, 300);
    } catch (e) {
      return new Response("NS didn't answer", { status: 502, headers: cors });
    }
  }

  if (url.pathname === "/ns/price") {
    const from = (url.searchParams.get("from") || "").toUpperCase();
    const to = (url.searchParams.get("to") || "").toUpperCase();
    const when = url.searchParams.get("dateTime") || "";
    const cls = url.searchParams.get("travelClass") || "2";
    if (!STATION.test(from) || !STATION.test(to) || (when && !WHEN.test(when)) || !/^[12]$/.test(cls))
      return new Response("Bad request", { status: 400, headers: cors });
    if (!NS_KEY) return new Response("No NS key set", { status: 501, headers: cors });
    try {
      const q = `fromStation=${from}&toStation=${to}&travelClass=${cls === "1" ? "FIRST_CLASS" : "SECOND_CLASS"}&travelType=single&adults=1` +
        (when ? `&plannedFromTime=${encodeURIComponent(when)}` : "");
      for (const v of ["v3", "v2"]) {
        const r = await fetchImpl(`${GW}/reisinformatie-api/api/${v}/price?${q}`, { headers });
        if (r.status === 200) return json(await r.text(), 200, cors, 3600);
        if (r.status === 401 || r.status === 403 || r.status === 429) return json(await r.text(), r.status, cors, 60);
      }
      // NS's trip planner has the fares on every trip: the first one's.
      const tq = `fromStation=${from}&toStation=${to}` + (when ? `&dateTime=${encodeURIComponent(when)}` : "");
      const t = await fetchImpl(`${GW}/reisinformatie-api/api/v3/trips?${tq}`, { headers });
      if (t.status !== 200) return json(await t.text(), t.status, cors, 60);
      const d = await t.json();
      const trip = ((d && d.trips) || []).find((x) => x && (x.productFare || x.fares)) || null;
      if (!trip) return json(JSON.stringify({ source: "trips", fares: [] }), 200, cors, 600);
      return json(JSON.stringify({ source: "trips", fares: trip.fares || [], productFare: trip.productFare || null }), 200, cors, 3600);
    } catch (e) {
      return new Response("NS didn't answer", { status: 502, headers: cors });
    }
  }

  if (url.pathname === "/ns/ovfiets") {
    const station = (url.searchParams.get("station") || "").toUpperCase();
    const raw = url.searchParams.get("raw") === "1";
    for (const k of url.searchParams.keys()) if (k !== "station" && k !== "raw") return new Response("Bad request", { status: 400, headers: cors });
    if (!STATION.test(station)) return new Response("Bad request", { status: 400, headers: cors });
    if (!NS_KEY) return new Response("No NS key set", { status: 501, headers: cors });
    try {
      let last = null;
      for (const path of [`/places-api/v2/ovfiets?station_code=${station}`, `/places-api/v2/places?type=ovfiets&station_code=${station}`]) {
        const r = await fetchImpl(GW + path, { headers });
        if (r.status === 200) {
          const text = await r.text();
          if (raw) return json(text, 200, cors, 300);
          let d = null;
          try { d = JSON.parse(text); } catch (e) { d = null; }
          const slim = slimOvfiets(d, station);
          if (slim.locations.length > 0 || path.includes("/places?")) return json(JSON.stringify(slim), 200, cors, 300);
          last = { status: 200, text: JSON.stringify(slim) };
          continue;
        }
        if (r.status === 401 || r.status === 403 || r.status === 429) return json(await r.text(), r.status, cors, 60);
        last = { status: r.status, text: await r.text() };
      }
      return json(last.text, last.status, cors, 60);
    } catch (e) {
      return new Response("NS didn't answer", { status: 502, headers: cors });
    }
  }

  return null;
}
