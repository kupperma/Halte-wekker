// Haltewekker relay (Cloudflare Worker), deployed from GitHub (folder: relay).
// 1. Passes Transitous requests through:   /?url=https://api.transitous.org/...
// 2. Gets NS departures with platforms:     /ns/departures?station=EHV
// 3. Gets NS trips with crowd forecasts:    /ns/trips?from=EHV&to=BD&dateTime=...
//    Needs a free NS API key saved as the secret NS_KEY (Settings → Variables and Secrets).
export default {
  async fetch(request, env) {
    const cors = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, OPTIONS",
    };
    if (request.method === "OPTIONS") return new Response(null, { headers: cors });
    const url = new URL(request.url);

    if (url.pathname === "/ns/departures") {
      const station = (url.searchParams.get("station") || "").toUpperCase();
      if (!/^[A-Z]{2,5}$/.test(station)) return new Response("Unknown station", { status: 400, headers: cors });
      if (!env.NS_KEY) return new Response("No NS key set", { status: 501, headers: cors });
      try {
        const r = await fetch(
          `https://gateway.apiportal.ns.nl/reisinformatie-api/api/v2/departures?station=${station}&maxJourneys=40`,
          { headers: { "Ocp-Apim-Subscription-Key": env.NS_KEY } }
        );
        return new Response(await r.text(), {
          status: r.status,
          headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "max-age=20" },
        });
      } catch (e) {
        return new Response("NS didn't answer", { status: 502, headers: cors });
      }
    }

    if (url.pathname === "/ns/trips") {
      // Trip planner, used for how busy NS expects each train to be.
      const from = (url.searchParams.get("from") || "").toUpperCase();
      const to = (url.searchParams.get("to") || "").toUpperCase();
      const when = url.searchParams.get("dateTime") || "";
      if (!/^[A-Z]{2,5}$/.test(from) || !/^[A-Z]{2,5}$/.test(to) || (when && !/^[0-9T:+\-.Z]{10,30}$/.test(when)))
        return new Response("Bad request", { status: 400, headers: cors });
      if (!env.NS_KEY) return new Response("No NS key set", { status: 501, headers: cors });
      try {
        const q = `fromStation=${from}&toStation=${to}` + (when ? `&dateTime=${encodeURIComponent(when)}` : "");
        const r = await fetch(`https://gateway.apiportal.ns.nl/reisinformatie-api/api/v3/trips?${q}`, {
          headers: { "Ocp-Apim-Subscription-Key": env.NS_KEY },
        });
        return new Response(await r.text(), {
          status: r.status,
          headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "max-age=60" },
        });
      } catch (e) {
        return new Response("NS didn't answer", { status: 502, headers: cors });
      }
    }

    const target = url.searchParams.get("url") || "";
    if (!/^https:\/\/api\.transitous\.org\//.test(target)) {
      return new Response("Haltewekker relay is running.", { headers: cors });
    }
    try {
      const r = await fetch(target, {
        headers: { "User-Agent": "Haltewekker/1.0 (https://github.com/kupperma/Halte-wekker)" },
      });
      return new Response(await r.text(), {
        status: r.status,
        headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
      });
    } catch (e) {
      return new Response("Transitous didn't answer", { status: 502, headers: cors });
    }
  },
};
