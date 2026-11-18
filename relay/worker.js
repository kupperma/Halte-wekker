// Haltewekker relay (Cloudflare Worker), deployed from GitHub (folder: relay).
// 1. Passes Transitous requests through:   /?url=https://api.transitous.org/...
// 2. Gets NS departures with platforms:     /ns/departures?station=EHV
// 3. Gets NS trips with crowd forecasts:    /ns/trips?from=EHV&to=BD&dateTime=...
// 4. Gets one train from the Virtual Train API: /ns/train?num=1126&station=EHV
// 5. Gets the positions of every train from the Virtual Train API: /ns/vehicles (no place of yours is sent)
//    Needs a free NS API key saved as the secret NS_KEY (Settings → Variables and Secrets).
// 6. Friends (0.25): end-to-end encrypted mailboxes under /f/v1/… and the share-link page /add (see friends.js).
//    Stored in a Durable Object with SQLite storage, declared in wrangler.jsonc: nothing to set up by hand.
import { DurableObject } from "cloudflare:workers";
import { friends, FriendsCore } from "./friends.js";

export class Friends extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.core = new FriendsCore(ctx, env);
  }
  fetch(request) { return this.core.fetch(request); }
  alarm() { return this.core.alarm(); }
}

export default {
  async fetch(request, env) {
    const cors = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, OPTIONS",
    };
    if (request.method === "OPTIONS") return new Response(null, { headers: cors });
    const url = new URL(request.url);
    if (url.pathname.startsWith("/f/") || url.pathname === "/add") return friends(request, env, url);
    // The key may be saved as NS_KEY or NS-KEY.
    const NS_KEY = env.NS_KEY || env["NS-KEY"];

    if (url.pathname === "/ns/departures") {
      const station = (url.searchParams.get("station") || "").toUpperCase();
      if (!/^[A-Z]{2,5}$/.test(station)) return new Response("Unknown station", { status: 400, headers: cors });
      if (!NS_KEY) return new Response("No NS key set", { status: 501, headers: cors });
      try {
        const r = await fetch(
          `https://gateway.apiportal.ns.nl/reisinformatie-api/api/v2/departures?station=${station}&maxJourneys=40`,
          { headers: { "Ocp-Apim-Subscription-Key": NS_KEY } }
        );
        return new Response(await r.text(), {
          status: r.status,
          headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "max-age=20" },
        });
      } catch (e) {
        return new Response("NS didn't answer", { status: 502, headers: cors });
      }
    }

    if (url.pathname === "/ns/train") {
      // Virtual Train API: one train's composition and how busy it is.
      const num = url.searchParams.get("num") || "";
      const station = (url.searchParams.get("station") || "").toUpperCase();
      const v = url.searchParams.get("v") || "1";
      const features = url.searchParams.get("features") ?? "druktev2";
      if (!/^\d{1,6}$/.test(num) || (station && !/^[A-Z]{2,5}$/.test(station)) || !/^[12]$/.test(v) || !/^[a-z0-9,]{0,60}$/i.test(features))
        return new Response("Bad request", { status: 400, headers: cors });
      if (!NS_KEY) return new Response("No NS key set", { status: 501, headers: cors });
      try {
        const path = `virtual-train-api/api/v${v}/trein/${num}` + (station ? `/${station}` : "");
        const r = await fetch(`https://gateway.apiportal.ns.nl/${path}${features ? "?features=" + encodeURIComponent(features) : ""}`, {
          headers: { "Ocp-Apim-Subscription-Key": NS_KEY },
        });
        return new Response(await r.text(), {
          status: r.status,
          headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "max-age=60" },
        });
      } catch (e) {
        return new Response("NS didn't answer", { status: 502, headers: cors });
      }
    }

    if (url.pathname === "/ns/vehicles") {
      // Virtual Train API: where every train is now (all of them: the app never sends where you are). Takes no
      // parameters; NS's answer is passed on as it is, and the app reads it defensively.
      if ([...url.searchParams.keys()].length > 0) return new Response("Bad request", { status: 400, headers: cors });
      if (!NS_KEY) return new Response("No NS key set", { status: 501, headers: cors });
      try {
        const headers = { "Ocp-Apim-Subscription-Key": NS_KEY };
        let r = await fetch("https://gateway.apiportal.ns.nl/virtual-train-api/api/vehicle", { headers });
        if (r.status === 404) r = await fetch("https://gateway.apiportal.ns.nl/virtual-train-api/vehicle", { headers });
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
      if (!NS_KEY) return new Response("No NS key set", { status: 501, headers: cors });
      try {
        const q = `fromStation=${from}&toStation=${to}` + (when ? `&dateTime=${encodeURIComponent(when)}` : "");
        const r = await fetch(`https://gateway.apiportal.ns.nl/reisinformatie-api/api/v3/trips?${q}`, {
          headers: { "Ocp-Apim-Subscription-Key": NS_KEY },
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
