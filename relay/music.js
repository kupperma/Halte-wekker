// Haltewekker relay (2026-11-27): "Listening now" through Last.fm, for an app whose music comes from Spotify (or any
// player) scrobbling to the user's own Last.fm account. The Last.fm API key stays here, as the secret LASTFM_API_KEY
// (Settings → Variables and Secrets); it is never in an app or in the repository.
//
//  GET /music/v1/now?user=<last.fm username>[&app=spotify|lastfm]
//    -> 200 {"nowPlaying":true,"title","artist","app":"Spotify"|"Last.fm","url","coverUrl"?,"at"}
//       200 {"nowPlaying":false,"at"}            (nothing playing right now: no earlier track is ever passed on)
//       400 bad_user · 404 no_user · 403 private (the user hides their listening) · 429 slow_down · 502 lastfm
//       503 not_configured (no LASTFM_API_KEY yet: the app says "Last.fm isn't set up yet")
//  Only the one track playing now: title, artist, the app it says, a link (a Spotify search for app=spotify, else the
//  track's www.last.fm page) and the largest cover on Last.fm's image host. Kept 30 s per user in this Worker; at most
//  30 asks a minute per network address (hashed, in memory). Nothing is logged or stored.

const LASTFM = "https://ws.audioscrobbler.com/2.0/";
const USER = /^[A-Za-z][A-Za-z0-9_-]{1,14}$/;
const CACHE_FOR = 30_000;
const PER_MINUTE = 30;
const KEEP = 500;
/** Last.fm's grey star for a track without a cover. */
const NO_COVER = "2a96cbd8b46e442fc41c2b86b821562f";

const cache = new Map();   // "user|app" -> {at, status, body}
const asks = new Map();    // ip hash -> {minute, n}

/** Only for the tests: forget the cache and the counters. */
export function resetMusic() { cache.clear(); asks.clear(); }

const clean = (s, max) => (typeof s === "string" ? s : "").replace(/[\u0000-\u001f\u007f]/g, "").replace(/\s+/g, " ").trim().slice(0, max).trim();

/** The ISO time with whole seconds: "2027-01-15T07:59:30Z". */
export const iso = (ms) => new Date(Math.floor(ms / 1000) * 1000).toISOString().replace(".000Z", "Z");

function cover(images) {
  const list = Array.isArray(images) ? images : [];
  for (let i = list.length - 1; i >= 0; i--) {
    const u = list[i] && typeof list[i]["#text"] === "string" ? list[i]["#text"] : "";
    if (!u || u.includes(NO_COVER) || u.length > 500) continue;
    try {
      const x = new URL(u);
      if (x.protocol === "https:" && x.hostname === "lastfm.freetls.fastly.net") return x.href;
    } catch (e) { /* not a link */ }
  }
  return null;
}

function trackPage(u) {
  if (typeof u !== "string" || u.length > 500) return null;
  try {
    const x = new URL(u);
    return x.protocol === "https:" && x.hostname === "www.last.fm" ? x.href : null;
  } catch (e) { return null; }
}

/** Last.fm's user.getrecenttracks answer as the app gets it (`app`: "spotify" or "lastfm"; `now`: ms). */
export function slimRecent(answer, app, now) {
  const rt = answer && answer.recenttracks;
  const raw = rt ? rt.track : null;
  const tracks = Array.isArray(raw) ? raw : raw ? [raw] : [];
  const t = tracks.find((x) => x && x["@attr"] && String(x["@attr"].nowplaying) === "true");
  if (!t) return { nowPlaying: false, at: iso(now) };
  const title = clean(t.name, 80);
  const artist = clean(t.artist && typeof t.artist === "object" ? (t.artist["#text"] ?? t.artist.name) : t.artist, 60);
  if (!title) return { nowPlaying: false, at: iso(now) };
  const spotify = app === "spotify";
  const out = {
    nowPlaying: true,
    title,
    artist,
    app: spotify ? "Spotify" : "Last.fm",
    url: spotify ? "https://open.spotify.com/search/" + encodeURIComponent((artist + " " + title).trim()) : trackPage(t.url),
    coverUrl: cover(t.image),
    at: iso(now),
  };
  if (!out.url) delete out.url;
  if (!out.coverUrl) delete out.coverUrl;
  return out;
}

async function ipKey(request) {
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("hw-music-v1:" + ip));
  return [...new Uint8Array(d).slice(0, 12)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function trim(map) {
  while (map.size > KEEP) map.delete(map.keys().next().value);
}

/** /music/v1/now (null for any other path). `fetchImpl` and `nowFn` for the tests. */
export async function music(request, env, url, cors, fetchImpl = fetch, nowFn = Date.now) {
  if (url.pathname !== "/music/v1/now") return null;
  const answer = (status, body, maxAge = 0) => new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json", "Cache-Control": maxAge > 0 ? `max-age=${maxAge}` : "no-store" },
  });
  if (request.method !== "GET") return answer(405, { error: "method" });
  for (const k of url.searchParams.keys()) if (k !== "user" && k !== "app") return answer(400, { error: "bad_request" });
  const user = url.searchParams.get("user") || "";
  const app = (url.searchParams.get("app") || "lastfm").toLowerCase();
  if (!USER.test(user)) return answer(400, { error: "bad_user" });
  if (app !== "spotify" && app !== "lastfm") return answer(400, { error: "bad_app" });
  const key = env.LASTFM_API_KEY || env["LASTFM-API-KEY"];
  if (!key) return answer(503, { error: "not_configured", message: "Last.fm isn't set up on the relay yet." });

  const now = nowFn();
  const ip = await ipKey(request);
  const minute = Math.floor(now / 60_000);
  const a = asks.get(ip);
  if (a && a.minute === minute) {
    if (a.n >= PER_MINUTE) return answer(429, { error: "slow_down" });
    a.n += 1;
  } else {
    asks.delete(ip);
    asks.set(ip, { minute, n: 1 });
    trim(asks);
  }

  const id = user.toLowerCase() + "|" + app;
  const hit = cache.get(id);
  if (hit && now - hit.at < CACHE_FOR) return answer(hit.status, hit.body, hit.status === 200 ? 15 : 0);

  let status;
  let body;
  try {
    const q = `?method=user.getrecenttracks&user=${encodeURIComponent(user)}&limit=1&format=json&api_key=${encodeURIComponent(key)}`;
    const r = await fetchImpl(LASTFM + q, { headers: { "User-Agent": "Haltewekker-relay/1.0" } });
    let j = null;
    try { j = await r.json(); } catch (e) { j = null; }
    const err = j && typeof j.error === "number" ? j.error : null;
    if (err === 6) { status = 404; body = { error: "no_user" }; }
    else if (err === 17) { status = 403; body = { error: "private" }; }
    else if (err === 10 || err === 26) { status = 503; body = { error: "not_configured", message: "The relay's Last.fm key doesn't work." }; }
    else if (err === 29) { status = 429; body = { error: "slow_down" }; }
    else if (r.status !== 200 || !j || err !== null) { status = 502; body = { error: "lastfm" }; }
    else { status = 200; body = slimRecent(j, app, now); }
  } catch (e) {
    status = 502;
    body = { error: "lastfm" };
  }
  if (status !== 502) {
    cache.delete(id);
    cache.set(id, { at: now, status, body });
    trim(cache);
  }
  return answer(status, body, status === 200 ? 15 : 0);
}
