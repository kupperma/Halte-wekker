// The live-trip page's script (served as /live/app.js by live.js). Kept as plain JavaScript in a String.raw, so it
// reads as code: no backticks and no dollar-brace in it. It runs in the viewer's browser only.
//
// What it does: reads the link's token (path) and key (fragment, never sent anywhere), polls /live/v1/get every 15 s
// while the page is visible, decrypts the trip with WebCrypto and draws it: a dark map (MapLibre GL JS + OpenFreeMap,
// when they load) with the ride's road, its stops, the destination and the vehicle gliding between updates, and a card
// with who, where, the big arrival time, the legs and the whole trip as a timeline. Payload v1 (0.30 apps: one ride and
// the trip's end) and v2 (the whole trip, see the friends spec "As built (relay 2026-11-27)") both draw. Messages to the
// sharer are locked with the same key (AAD "hw-live-msg-v1\n" + token); their answers (AAD "hw-live-reply-v1\n" + token)
// come with each poll. `window.HWLive` holds the pure parts, for relay/test-live.mjs.
export const APP_JS = String.raw`(function () {
  "use strict";
  var W = window, D = document;
  var token = (location.pathname.split("/")[2] || "").replace(/\/$/, "");
  var key = null, timer = null, ticker = null, over = false, errors = 0, last = null, lastAt = 0, model = null;
  var seen = 0, replies = {}, sending = false;
  var TILES = "https://tiles.openfreemap.org";
  var reduce = false;
  try { reduce = !!(W.matchMedia && W.matchMedia("(prefers-reduced-motion: reduce)").matches); } catch (e) {}

  // MARK: the key (only ever in the fragment). "#<key>" or "#k=<key>", %-encoded or not, with whatever an app glued
  // on after it; standard base64 ("+", "/") reads too.
  function keyFrom(h) {
    var s = String(h || "").replace(/^#/, "");
    try { s = decodeURIComponent(s); } catch (e) {}
    s = s.replace(/\s+/g, "");
    var m = s.match(/(?:^|[&;?])k=([^&;]*)/);
    if (m) s = m[1];
    s = s.replace(/\+/g, "-").replace(/\//g, "_");
    var b = s.match(/^[A-Za-z0-9_-]{43}/);
    return b ? b[0] : s.replace(/=+$/, "");
  }
  // A key that worked once is kept in this browser (for this link only); it goes when the link has ended.
  var saved = null;
  try { saved = W.localStorage || null; } catch (e) { saved = null; }
  function getItem(k) { try { return saved ? saved.getItem(k) || "" : ""; } catch (e) { return ""; } }
  function setItem(k, v) { try { if (saved) saved.setItem(k, v); } catch (e) {} }
  function dropItem(k) { try { if (saved) saved.removeItem(k); } catch (e) {} }
  function forget() { dropItem("hw-live:" + token); dropItem("hw-live-sent:" + token); }
  var keyText = keyFrom(location.hash), keyKept = false;
  if (!keyText) { keyText = getItem("hw-live:" + token); keyKept = !!keyText; }

  function b64u(s) {
    if (!/^[A-Za-z0-9_-]+={0,2}$/.test(s)) return null;
    s = s.replace(/=+$/, "").replace(/-/g, "+").replace(/_/g, "/");
    while (s.length % 4) s += "=";
    var b = atob(s), u = new Uint8Array(b.length);
    for (var i = 0; i < b.length; i++) u[i] = b.charCodeAt(i);
    return u;
  }
  function toB64u(u) {
    var s = "";
    for (var i = 0; i < u.length; i++) s += String.fromCharCode(u[i]);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  // MARK: words (English; times in the viewer's clock)
  function two(n) { return (n < 10 ? "0" : "") + n; }
  function hhmm(t) { var d = new Date(t * 1000); return two(d.getHours()) + ":" + two(d.getMinutes()); }
  function num(x) { return typeof x === "number" && isFinite(x) ? x : null; }
  function str(x, max) { return typeof x === "string" ? x.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, max || 60) : ""; }
  function join(a) { return a.filter(function (x) { return !!x; }).join(" · "); }
  function cap(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }
  function plural(n, one) { return n + " " + one + (n === 1 ? "" : "s"); }
  function inMin(t, now) {
    if (num(t) === null) return "";
    var m = Math.round((t - now) / 60);
    return m <= 0 ? "now" : "in " + m + " min";
  }
  function ago(sec) {
    sec = Math.max(0, Math.round(sec));
    return sec < 60 ? sec + " s" : sec < 3600 ? Math.round(sec / 60) + " min" : Math.round(sec / 3600) + " h";
  }
  function lateWords(n) { return num(n) === null ? "" : n >= 1 ? n + " min late" : "on time"; }
  function isRide(l) { return l && l.mode !== "walk" && l.mode !== "more"; }
  function isTrain(l) { return l.mode === "train"; }
  /// "bus 305", "the IC 3512", "the IC", "the train", "the bus", "tram 1"
  function vehicle(l) {
    var line = str(l.line, 20), n = str(l.num, 12), mode = str(l.mode, 12) || "bus";
    if (mode === "train") return line ? "the " + (n ? line + " " + n : line) : "the train";
    return line ? mode + " " + line : "the " + mode;
  }
  /// "Bus 305", "IC 3512", "Train"
  function vtitle(l) {
    var line = str(l.line, 20), n = str(l.num, 12), mode = str(l.mode, 12) || "bus";
    if (mode === "train") return line ? (n ? line + " " + n : line) : "Train";
    return line ? cap(mode) + " " + line : cap(mode);
  }
  function chipText(l) { return str(l.line, 8) || (isTrain(l) ? "Train" : cap(str(l.mode, 8) || "bus")); }
  function colour(l) {
    if (l && /^[0-9A-Fa-f]{6}$/.test(l.color || "")) return "#" + l.color;
    var m = l ? l.mode : "bus", line = str(l && l.line, 20).toUpperCase();
    if (m === "train") return /^(SPR|SPRINTER|S\d|SNG)/.test(line) ? "#0A93B5" : "#3B44B0";
    if (m === "tram" || m === "metro") return "#7A55B0";
    if (m === "ferry") return "#2A7898";
    return "#E0632E";
  }
  function plat(l) {
    var p = str(l.depPlatform, 8);
    return p ? (isTrain(l) ? "platform " + p : "stop " + p) : "";
  }
  function seat(l) {
    var c = num(l.coach), d = str(l.deck, 10);
    return c !== null ? "coach " + c + (d ? ", " + d + " deck" : "") : "";
  }
  var FACES = ["#0E7A55", "#3B44B0", "#0A93B5", "#E0632E", "#7A55B0", "#2A7898"];
  function face(s, n) {
    var c = /^[0-9A-Fa-f]{6}$/.test(s.face || "") ? "#" + s.face : null;
    if (!c) {
      var h = 0;
      for (var i = 0; i < n.length; i++) h = (h * 31 + n.charCodeAt(i)) & 0xffff;
      c = FACES[h % FACES.length];
    }
    var ch = Array.from ? Array.from(n)[0] || "?" : n.charAt(0) || "?";
    return { letter: ch.toUpperCase(), color: c };
  }
  function stage(s) { return ["waiting", "riding", "change", "arrived"].indexOf(s.state) >= 0 ? s.state : "riding"; }

  // MARK: the road (Google's encoded polyline, 5 decimals)
  function decode(p) {
    var out = [], i = 0, lat = 0, lon = 0;
    if (typeof p !== "string") return out;
    while (i < p.length && out.length < 1000) {
      for (var k = 0; k < 2; k++) {
        var shift = 0, res = 0, b;
        do { b = p.charCodeAt(i++) - 63; res |= (b & 31) << shift; shift += 5; } while (b >= 32 && i < p.length);
        var d = res & 1 ? ~(res >> 1) : res >> 1;
        if (k === 0) lat += d; else lon += d;
      }
      out.push([lon / 1e5, lat / 1e5]);
    }
    return out;
  }
  /// Splits a road at the point nearest p: [done, rest] (each [[lon, lat]…]).
  function split(pts, p) {
    if (!p || pts.length < 2) return [[], pts];
    var k = Math.cos(p[1] * Math.PI / 180), best = 0, bestD = Infinity, bestF = 0;
    for (var i = 0; i + 1 < pts.length; i++) {
      var ax = pts[i][0] * k, ay = pts[i][1], bx = pts[i + 1][0] * k, by = pts[i + 1][1], px = p[0] * k, py = p[1];
      var dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
      var f = l2 > 0 ? Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) : 0;
      var ex = ax + f * dx - px, ey = ay + f * dy - py, d = ex * ex + ey * ey;
      if (d < bestD) { bestD = d; best = i; bestF = f; }
    }
    var a = pts[best], b2 = pts[best + 1];
    var q = [a[0] + bestF * (b2[0] - a[0]), a[1] + bestF * (b2[1] - a[1])];
    return [pts.slice(0, best + 1).concat([q]), [q].concat(pts.slice(best + 1))];
  }

  // MARK: music ("listening now"): only from these services, covers only from their image hosts
  function music(m, now) {
    if (!m || typeof m !== "object") return null;
    var title = str(m.title, 80);
    if (!title) return null;
    var at = typeof m.at === "string" ? Date.parse(m.at) / 1000 : num(m.at);
    if (!at || isNaN(at) || now - at > 600) return null;
    function host(u, ok) {
      if (typeof u !== "string" || u.length > 500) return "";
      try { var x = new URL(u); return x.protocol === "https:" && ok(x.hostname) ? x.href : ""; } catch (e) { return ""; }
    }
    return {
      title: title, sub: join([str(m.artist, 60), str(m.app, 20)]),
      url: host(m.url, function (h) { return h === "open.spotify.com" || h === "music.apple.com" || h === "www.last.fm"; }),
      cover: host(m.coverUrl, function (h) { return h === "i.scdn.co" || /\.mzstatic\.com$/.test(h) || h === "lastfm.freetls.fastly.net"; }),
    };
  }

  // MARK: the view: everything the page shows, from a state (pure)
  function view(s, relayAt, now) {
    var n = str(s.name, 40) || "Your friend", st = stage(s);
    var legs = Array.isArray(s.legs) ? s.legs.filter(function (l) { return l && typeof l === "object"; }).slice(0, 12) : [];
    var v2 = legs.length > 0, cur = 0;
    if (!v2) {
      legs = [{ mode: str(s.mode, 12) || "bus", line: s.line, num: s.num, from: s.from, to: s.to, dep: s.dep, arr: s.eta, late: s.late }];
      if (s.dest && s.dest !== s.to) legs.push({ mode: "more", to: s.dest, arr: s.end });
    } else {
      cur = Math.max(0, Math.min(legs.length - 1, Math.floor(num(s.leg) || 0)));
      while (cur < legs.length - 1 && !isRide(legs[cur])) cur++;
    }
    var l = legs[cur], lastLeg = legs[legs.length - 1];
    var dest = str(lastLeg.to) || str(s.dest) || str(s.to);
    var end = num(s.end) !== null ? s.end : num(lastLeg.arr);
    var eta = num(s.eta) !== null ? s.eta : num(l.arr);
    var dep = num(s.dep) !== null ? s.dep : num(l.dep);
    var late = num(s.late) !== null ? s.late : num(l.late);
    var stops = v2 && Array.isArray(s.stops) ? s.stops.filter(function (x) { return x && num(x.lat) !== null && num(x.lon) !== null; }).slice(0, 80) : [];
    var next = Math.max(0, Math.min(stops.length - 1, Math.floor(num(s.next) || 0)));
    var stopsLeft = stops.length ? stops.length - next : 0;
    var t = Math.min(num(s.t) || relayAt || now, relayAt || num(s.t) || now), age = now - t;
    var stale = st !== "arrived" && age > 180;
    var almost = st === "riding" && eta !== null && (eta - now <= 180 || (stops.length > 1 && next >= stops.length - 1 && eta - now <= 300));
    var nextRide = null;
    for (var i = cur + 1; i < legs.length; i++) if (isRide(legs[i])) { nextRide = legs[i]; break; }
    var col = colour(l);
    var m = { face: face(s, n), col: col, eyebrow: { text: "Live", cls: "" }, head: "", sub: "", big: null, note: "", legs: [],
      timeline: [], age: null, msgs: s.inbox === true, name: n, music: music(s.music, now), title: "" };
    if (st === "arrived") m.eyebrow = { text: "Arrived", cls: "" };
    else if (stale) m.eyebrow = { text: "Last seen " + hhmm(t), cls: "grey" };
    else if (almost) m.eyebrow = { text: "Almost there", cls: "almost" };
    else if (st === "waiting") m.eyebrow = { text: "Waiting", cls: "" };
    else if (st === "change") m.eyebrow = { text: "Changing", cls: "" };
    var pos = s.pos && num(s.pos.lat) !== null && num(s.pos.lon) !== null ? s.pos : null;
    var posWords = "";
    if (pos && num(pos.at) !== null) posWords = (pos.src === "gps" ? "GPS " : "phone ") + ago(now - pos.at);
    // who and where
    if (st === "arrived") {
      m.head = n + " arrived";
      m.sub = join([str(s.to) || dest, num(s.eta) !== null ? hhmm(s.eta) : ""]);
      m.note = "The live trip has ended. The link stops working soon.";
    } else if (st === "waiting") {
      m.head = n + " is waiting for " + vehicle(l);
      m.sub = join([str(l.from) ? "at " + str(l.from) : "", dep !== null ? "leaves " + hhmm(dep) : "", lateWords(late)]);
    } else if (st === "change") {
      var at = str(l.from) || str(s.from);
      m.head = n + " is changing" + (at ? " at " + at : "");
      m.sub = l.line ? "then " + vehicle(l) + (str(l.to) ? " to " + str(l.to) : "") + (dep !== null ? " at " + hhmm(dep) : "") : "";
      var walk = cur > 0 && legs[cur - 1].mode === "walk" ? legs[cur - 1] : null;
      var leaves = vtitle(l) + " leaves " + (dep !== null ? inMin(dep, now) : "soon");
      if (walk && num(walk.arr) !== null && now < walk.arr) m.note = join(["Walking " + (num(walk.mins) || Math.max(1, Math.round((walk.arr - walk.dep) / 60))) + " min" + (plat(l) ? " to " + plat(l) : ""), leaves]);
      else m.note = plat(l) ? join(["Waiting on " + plat(l), leaves]) : vtitle(l) + (str(l.to) ? " to " + str(l.to) : "") + " leaves " + (dep !== null ? hhmm(dep) + " (" + inMin(dep, now) + ")" : "soon");
    } else if (almost) {
      m.head = "Arriving at " + (str(l.to) || dest);
      m.sub = join([stops.length > 1 && next >= stops.length - 1 ? "next stop" : "", inMin(eta, now)]);
      if (nextRide) m.note = "Change to " + vtitle(nextRide) + (str(nextRide.to) ? " to " + str(nextRide.to) : "") + (plat(nextRide) ? " · " + plat(nextRide) : "") +
        (num(nextRide.dep) !== null ? " · leaves " + hhmm(nextRide.dep) + (eta !== null && nextRide.dep > eta ? " (" + Math.round((nextRide.dep - eta) / 60) + " min)" : "") : "");
    } else {
      m.head = n + " is on " + vehicle(l);
      m.sub = join([str(l.to) ? "to " + str(l.to) : "", lateWords(late)]);
    }
    // the big time
    var thenP = dest && dest !== str(l.to) && end !== null ? { place: "Then " + dest, time: hhmm(end) } : null;
    if (st === "riding" && eta !== null) {
      m.big = { place: str(l.to), time: hhmm(eta), sub: join([inMin(eta, now), stopsLeft ? plural(stopsLeft, "stop") : ""]), then: thenP };
    } else if (st === "change" && num(l.arr) !== null && str(l.to)) {
      // (the note says where and when it leaves: the big time is where that ride gets to)
      m.big = { place: str(l.to), time: hhmm(l.arr), sub: join(["arrives", vtitle(l)]), then: thenP };
    } else if ((st === "waiting" || st === "change") && dep !== null) {
      m.big = { place: join([vtitle(l) + " leaves" + (str(l.from) && st === "waiting" ? " " + str(l.from) : ""), plat(l)]), time: hhmm(dep), sub: join([inMin(dep, now), lateWords(late)]), then: thenP };
    }
    // the legs
    for (var j = 0; j < legs.length; j++) {
      var g = legs[j], state = st === "arrived" || j < cur ? "done" : j === cur ? "cur" : "next";
      if (g.mode === "walk") m.legs.push({ kind: "walk", text: "🚶" + (j === legs.length - 1 && str(g.to) ? " " + str(g.to) : ""), state: state });
      else if (g.mode === "more") m.legs.push({ kind: "more", text: str(g.to), state: state });
      else m.legs.push({ kind: "ride", text: chipText(g), color: colour(g), state: state });
    }
    m.timeline = timeline(legs, cur, st, s, now, posWords, stops, next, late, dest, end);
    m.age = st === "arrived" ? null : stale ? { text: (age > 600 ? "last seen " + hhmm(t) + " · the phone may be out of reach" : "last seen " + hhmm(t)), grey: true }
      : { text: ago(age), grey: false };
    m.title = m.head + " · Haltewekker";
    // the map
    var shape = v2 ? decode(s.shape) : [];
    m.map = {
      pos: st === "arrived" || !pos ? null : [pos.lon, pos.lat], old: !!pos && num(pos.at) !== null && now - pos.at > 120,
      label: chipText(l), shape: shape, waiting: st === "waiting" || st === "change", arrived: st === "arrived",
      stops: stops.map(function (x, k) { return { lon: x.lon, lat: x.lat, done: st === "arrived" || k < next }; }),
      dest: stops.length ? { lon: stops[stops.length - 1].lon, lat: stops[stops.length - 1].lat, name: str(l.to) } : null,
      key: cur + "|" + str(l.line) + "|" + str(l.to),
    };
    return m;
  }

  /// The whole trip, top to bottom: {time, title, sub, kind: "done" | "now" | "next"}.
  function timeline(legs, cur, st, s, now, posWords, stops, next, late, dest, end) {
    var out = [], arrived = st === "arrived", rides = [];
    for (var i = 0; i < legs.length; i++) if (isRide(legs[i])) rides.push(i);
    function tm(x) { return num(x) !== null ? hhmm(x) : ""; }
    for (var j = 0; j < rides.length; j++) {
      var k = rides[j], l = legs[k];
      var done = arrived || k < cur || (k === cur && st === "riding");
      if (!arrived && k === cur && (st === "waiting" || st === "change")) {
        var p = plat(l);
        out.push({ time: "now", kind: "now", title: p ? "Waiting " + (isTrain(l) ? "on " : "at ") + p : (j === 0 ? "Waiting at " : "Changing at ") + (str(l.from) || "the stop"),
          sub: join([vtitle(l) + (str(l.to) ? " to " + str(l.to) : "") + " leaves " + (num(l.dep) !== null ? inMin(l.dep, now) : "soon"), lateWords(num(s.late) !== null ? s.late : l.late)]) });
      } else if (j === 0) {
        out.push({ time: tm(l.dep), kind: done ? "done" : "next", title: str(l.from) || "Start", sub: (done ? "got on " : "gets on ") + vehicle(l) });
      } else {
        out.push({ time: tm(l.dep), kind: done ? "done" : "next", title: vtitle(l) + (str(l.to) ? " to " + str(l.to) : ""), sub: join([str(l.from), plat(l), seat(l)]) });
      }
      if (!arrived && k === cur && st === "riding") {
        var nx = stops.length ? str(stops[next].name) : "";
        out.push({ time: "now", kind: "now", title: cap("on " + vehicle(l)), sub: join([nx, lateWords(late), posWords]) });
      }
      var nr = j + 1 < rides.length ? rides[j + 1] : -1;
      if (nr >= 0) {
        var w = legs[nr - 1].mode === "walk" ? legs[nr - 1] : null, n2 = legs[nr];
        var off = arrived || cur >= nr || cur > k;
        var wm = w ? num(w.mins) || (num(w.arr) !== null && num(w.dep) !== null ? Math.max(1, Math.round((w.arr - w.dep) / 60)) : 0) : 0;
        var to = plat(n2) ? " to " + plat(n2) : "";
        out.push({ time: tm(l.arr), kind: off ? "done" : "next", title: str(l.to),
          sub: off ? join(["got off", wm ? "walking to " + (plat(n2) || str(n2.from) || "the next stop") : ""]) : join(["change", wm ? "walk " + wm + " min" + to : to.slice(1)]) });
      } else if (legs[legs.length - 1].mode === "more") {
        if (str(l.to) && str(l.to) !== dest) out.push({ time: tm(l.arr), kind: arrived ? "done" : "next", title: str(l.to), sub: arrived ? "got off" : "gets off" });
      }
    }
    var lastL = legs[legs.length - 1];
    var walkEnd = lastL.mode === "walk" ? num(lastL.mins) || (num(lastL.arr) !== null && num(lastL.dep) !== null ? Math.max(1, Math.round((lastL.arr - lastL.dep) / 60)) : 0) : 0;
    if (dest) out.push({ time: arrived ? tm(s.eta) : tm(end), kind: arrived ? "done" : "next", title: dest,
      sub: arrived ? "arrived" : lastL.mode === "more" ? "there around " + tm(end) : join(["arrives", walkEnd ? walkEnd + " min walk" : ""]) });
    return out;
  }

  // MARK: the card
  function $(id) { return D.getElementById(id); }
  function text(id, t) { var e = $(id); e.textContent = t || ""; e.hidden = !t; return e; }
  function el(tag, cls, t) { var e = D.createElement(tag); if (cls) e.className = cls; if (t) e.textContent = t; return e; }
  function setCol(c) { try { D.documentElement.style.setProperty("--col", c); } catch (e) {} }

  function drawCard(m) {
    var f = $("face");
    f.textContent = m.face.letter; f.style.background = m.face.color;
    var eb = $("eyebrow"); eb.textContent = m.eyebrow.text; eb.className = "eyebrow " + m.eyebrow.cls;
    text("head", m.head); text("sub", m.sub);
    D.title = m.title;
    setCol(m.col);
    var a = $("age");
    if (m.age) { a.hidden = false; $("ageText").textContent = m.age.text; $("ageDot").className = m.age.grey ? "dot grey" : "dot"; } else a.hidden = true;
    var mu = $("music");
    if (m.music) {
      mu.hidden = false;
      $("muTitle").textContent = m.music.title; $("muSub").textContent = m.music.sub;
      var o = $("muOpen"); o.hidden = !m.music.url; if (m.music.url) o.href = m.music.url;
      var c = $("cover");
      if (m.music.cover && c.getAttribute && c.getAttribute("data-src") !== m.music.cover) {
        c.textContent = "";
        var img = el("img"); img.alt = ""; img.referrerPolicy = "no-referrer"; img.src = m.music.cover;
        c.appendChild(img); c.setAttribute("data-src", m.music.cover);
      } else if (!m.music.cover) { c.textContent = "♪"; if (c.setAttribute) c.setAttribute("data-src", ""); }
    } else mu.hidden = true;
    var b = $("big");
    if (m.big) {
      b.hidden = false;
      text("bigPlace", m.big.place); $("bigTime").textContent = m.big.time; text("bigSub", m.big.sub);
      var th = $("then"); th.hidden = !m.big.then;
      if (m.big.then) { $("thenPlace").textContent = m.big.then.place; $("thenTime").textContent = m.big.then.time; }
    } else b.hidden = true;
    text("note", m.note);
    var lg = $("legs"); lg.textContent = ""; lg.hidden = m.legs.length < 2;
    for (var i = 0; i < m.legs.length; i++) {
      var g = m.legs[i];
      if (i > 0) lg.appendChild(el("span", "", "→"));
      if (g.kind === "ride") { var ch = el("span", "chip " + g.state, g.text); ch.style.background = g.color; lg.appendChild(ch); }
      else lg.appendChild(el("span", g.state === "done" ? "done" : "", g.text));
    }
    var tl = $("tl"); tl.textContent = ""; tl.hidden = !m.timeline.length;
    for (var k = 0; k < m.timeline.length; k++) {
      var it = m.timeline[k], li = el("li", it.kind), body = el("div");
      li.appendChild(el("span", "tm", it.time)); li.appendChild(el("span", "pt"));
      body.appendChild(el("div", "ti", it.title)); if (it.sub) body.appendChild(el("div", "su", it.sub));
      li.appendChild(body); tl.appendChild(li);
    }
    drawMessages(m);
  }

  function hideAll() {
    ["sub", "big", "note", "legs", "tl", "msg", "music", "age"].forEach(function (id) { $(id).hidden = true; });
    $("openApp").hidden = true;
  }
  function ended(t, badge, cls) {
    over = true;
    clearTimeout(timer); clearInterval(ticker);
    hideAll();
    var eb = $("eyebrow"); eb.textContent = badge || "Ended"; eb.className = "eyebrow " + (cls || "grey");
    text("head", t);
    $("face").textContent = "·";
    mapClear();
  }
  // No key (or a broken one): not "Ended" while the trip is still shared. One look at the relay says which it is.
  function missingKey() {
    ended("This link is missing its key. Ask for the link again (all of it, with the part after the #).", "Key missing", "warn");
    text("sub", "Some apps cut a link short. In Haltewekker, “Copy link” gives the whole link to paste.");
    if (!/^[A-Za-z0-9_-]{22}$/.test(token)) return;
    fetch("/live/v1/get?t=" + encodeURIComponent(token), { cache: "no-store" }).then(function (r) {
      if (r.status === 404 || r.status === 410) { forget(); ended("This link has ended"); }
    }, function () {});
  }

  // MARK: messages (locked with the link's key; the relay only passes them on)
  var CHIPS = ["👋 On my way", "I’m at the station", "Running late", "Call me"];
  function sentList() { try { var a = JSON.parse(getItem("hw-live-sent:" + token) || "[]"); return Array.isArray(a) ? a : []; } catch (e) { return []; } }
  function seal(obj, aad) {
    var iv = crypto.getRandomValues(new Uint8Array(12));
    return crypto.subtle.encrypt({ name: "AES-GCM", iv: iv, additionalData: new TextEncoder().encode(aad + token), tagLength: 128 }, key,
      new TextEncoder().encode(JSON.stringify(obj))).then(function (ct) {
      var c = new Uint8Array(ct), out = new Uint8Array(13 + c.length);
      out[0] = 1; out.set(iv, 1); out.set(c, 13);
      return toB64u(out);
    });
  }
  function open(data, aad) {
    var box = b64u(data || "");
    if (!box || box.length < 29 || box[0] !== 1) return Promise.reject(new Error("bad box"));
    return crypto.subtle.decrypt({ name: "AES-GCM", iv: box.slice(1, 13), additionalData: new TextEncoder().encode(aad + token), tagLength: 128 },
      key, box.slice(13)).then(function (p) { return JSON.parse(new TextDecoder().decode(p)); });
  }
  function drawMessages(m) {
    var box = $("msg");
    box.hidden = !m.msgs || over;
    if (box.hidden) return;
    $("msgHead").textContent = "Send " + (m.name === "Your friend" ? "your friend" : m.name) + " a message";
    var ul = $("sent"); ul.textContent = "";
    var all = sentList().map(function (x) { return { at: x.at, text: x.text, mine: true, seq: x.seq }; });
    for (var q in replies) if (replies[q]) all.push({ at: replies[q].at, text: replies[q].text, mine: false });
    all.sort(function (a, b) { return a.at - b.at; });
    all.slice(-12).forEach(function (x) {
      var li = el("li", x.mine ? "" : "them", x.text);
      li.appendChild(el("span", "small", x.mine ? (x.seq <= seen ? "Seen ✓✓" : "Sent " + hhmm(x.at) + " ✓") : m.name + " · " + hhmm(x.at)));
      ul.appendChild(li);
    });
  }
  function info(t) { text("msgInfo", t); }
  function send() {
    var ta = $("msgText"), t = str(ta.value, 280), from = str($("msgName").value, 40);
    if (!t || sending || !key) return;
    sending = true; $("msgSend").disabled = true;
    setItem("hw-live-name:" + token, from);
    var at = Math.floor(Date.now() / 1000);
    seal({ from: from, fromKind: "web", text: t, at: at }, "hw-live-msg-v1\n").then(function (data) {
      return fetch("/live/v1/msg?t=" + encodeURIComponent(token), { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ data: data }) });
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (r.ok && j.seq) {
          var list = sentList().concat([{ seq: j.seq, at: j.at || at, text: t }]).slice(-20);
          setItem("hw-live-sent:" + token, JSON.stringify(list));
          ta.value = ""; info("");
        } else if (r.status === 429) info(j.error === "full" ? "This trip can’t take more messages." : "Wait a few seconds before sending another.");
        else if (r.status === 404 || r.status === 410) info("The live trip has ended.");
        else info("Couldn’t send it. Try again.");
      });
    }).catch(function () { info("Couldn’t send it. Check your connection."); }).then(function () {
      sending = false; $("msgSend").disabled = false;
      if (model) drawMessages(model);
    });
  }
  function setupMessages() {
    var chips = $("chips");
    CHIPS.forEach(function (c) {
      var b = el("button", "", c); b.type = "button";
      b.addEventListener("click", function () { $("msgText").value = c; try { $("msgText").focus(); } catch (e) {} });
      chips.appendChild(b);
    });
    $("msgName").value = getItem("hw-live-name:" + token);
    $("msgSend").addEventListener("click", send);
  }
  function takeReplies(list) {
    if (!Array.isArray(list)) return;
    list.forEach(function (r) {
      if (!r || replies[r.seq] !== undefined || typeof r.data !== "string") return;
      replies[r.seq] = null;
      open(r.data, "hw-live-reply-v1\n").then(function (o) {
        var t = str(o && o.text, 280);
        if (t) { replies[r.seq] = { text: t, at: num(o.at) || r.at }; if (model) drawMessages(model); }
      }, function () {});
    });
  }

  // MARK: the map (only when MapLibre loaded and the browser can draw it)
  var M = null, ready = false, vMark = null, dMark = null, shown = null, target = null, anim = 0, follow = true, framedKey = "", road = [], col = "#E0632E";
  function mapInit() {
    var ml = W.maplibregl;
    if (!ml || !ml.Map) { D.body.className += " nomap"; return; }
    try {
      M = new ml.Map({ container: "map", style: TILES + "/styles/dark", center: [5.3, 51.6], zoom: 8, attributionControl: false,
        dragRotate: false, pitchWithRotate: false, touchPitch: false, fadeDuration: reduce ? 0 : 300 });
    } catch (e) { M = null; D.body.className += " nomap"; return; }
    try { M.touchZoomRotate.disableRotation(); M.addControl(new ml.AttributionControl({ compact: true }), W.innerWidth >= 900 ? "bottom-right" : "top-left"); } catch (e) {}
    M.on("load", function () {
      var empty = { type: "FeatureCollection", features: [] };
      ["rest", "done", "stops"].forEach(function (id) { M.addSource(id, { type: "geojson", data: empty }); });
      M.addLayer({ id: "rest", type: "line", source: "rest", layout: { "line-cap": "round", "line-join": "round" }, paint: { "line-color": col, "line-width": 6, "line-opacity": 0.35 } });
      M.addLayer({ id: "done", type: "line", source: "done", layout: { "line-cap": "round", "line-join": "round" }, paint: { "line-color": col, "line-width": 6 } });
      M.addLayer({ id: "stops", type: "circle", source: "stops", paint: { "circle-radius": 5, "circle-color": "#111316", "circle-stroke-width": 3,
        "circle-stroke-color": col, "circle-stroke-opacity": ["case", ["get", "done"], 1, 0.45] } });
      ready = true;
      // (the credits folded to their (i), not over the card's top)
      try { var at = D.querySelector(".maplibregl-ctrl-attrib"); if (at) at.classList.remove("maplibregl-compact-show"); } catch (e) {}
      if (model) drawMap(model.map);
    });
    M.on("dragstart", function () { follow = false; $("recentre").hidden = false; });
    $("recentre").addEventListener("click", function () { follow = true; framedKey = ""; $("recentre").hidden = true; if (model) drawMap(model.map); });
  }
  function mapClear() {
    if (vMark) { vMark.remove(); vMark = null; }
    if (dMark) { dMark.remove(); dMark = null; }
    if (ready) ["rest", "done", "stops"].forEach(function (id) { M.getSource(id).setData({ type: "FeatureCollection", features: [] }); });
  }
  function line(c) { return { type: "FeatureCollection", features: c.length > 1 ? [{ type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: c } }] : [] }; }
  function drawRoad(p, mm) {
    if (!ready) return;
    var parts = mm.waiting ? [[], road] : mm.arrived || !p ? (mm.arrived ? [road, []] : [[], road]) : split(road, p);
    M.getSource("done").setData(line(parts[0]));
    M.getSource("rest").setData(line(parts[1]));
  }
  function padding() {
    var wide = W.innerWidth >= 900, card = $("card"), h = 0;
    try { h = card.getBoundingClientRect().height; } catch (e) {}
    return wide ? { top: 60, bottom: 60, left: 450, right: 60 } : { top: 70, bottom: Math.min(h, W.innerHeight * 0.7) + 30, left: 40, right: 40 };
  }
  function glide() {
    cancelAnimationFrame(anim);
    if (!shown || !target) return;
    var a = shown.slice(), b = target, t0 = Date.now(), dur = 10000, lastRoad = 0;
    function step() {
      var f = Math.min(1, (Date.now() - t0) / dur);
      shown = [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f];
      vMark.setLngLat(shown);
      if (Date.now() - lastRoad > 400 || f === 1) { lastRoad = Date.now(); drawRoad(shown, model.map); }
      if (f < 1) anim = requestAnimationFrame(step);
    }
    anim = requestAnimationFrame(step);
  }
  function far(a, b) { return Math.abs(a[0] - b[0]) > 0.05 || Math.abs(a[1] - b[1]) > 0.05; }
  function drawMap(mm) {
    if (!M || !mm) return;
    if (mm.shape.length > 1) road = mm.shape;
    else if (mm.stops.length > 1) road = mm.stops.map(function (x) { return [x.lon, x.lat]; });
    else road = [];
    if (ready && col !== model.col) {
      col = model.col;
      M.setPaintProperty("rest", "line-color", col); M.setPaintProperty("done", "line-color", col); M.setPaintProperty("stops", "circle-stroke-color", col);
    }
    if (ready) M.getSource("stops").setData({ type: "FeatureCollection", features: mm.stops.map(function (x) {
      return { type: "Feature", properties: { done: x.done }, geometry: { type: "Point", coordinates: [x.lon, x.lat] } }; }) });
    var ml = W.maplibregl;
    if (mm.dest) {
      if (!dMark) {
        var w = el("div", "destw"), lb = el("div", "lbl");
        w.appendChild(el("div", "dest")); w.appendChild(lb);
        dMark = new ml.Marker({ element: w }).setLngLat([mm.dest.lon, mm.dest.lat]).addTo(M);
      }
      dMark.setLngLat([mm.dest.lon, mm.dest.lat]);
      dMark.getElement().lastChild.textContent = mm.dest.name;
    } else if (dMark) { dMark.remove(); dMark = null; }
    if (mm.pos) {
      if (!vMark) { var vw = el("div", "mkw"); vw.appendChild(el("div", "mk")); vMark = new ml.Marker({ element: vw }).setLngLat(mm.pos).addTo(M); }
      var e = vMark.getElement().firstChild; e.textContent = mm.label; e.className = mm.old ? "mk old" : "mk"; e.style.background = model.col;
      target = mm.pos;
      if (!shown || reduce || far(shown, target) || D.visibilityState === "hidden") { shown = target.slice(); vMark.setLngLat(shown); drawRoad(shown, mm); }
      else glide();
    } else {
      if (vMark) { vMark.remove(); vMark = null; }
      shown = null; target = null;
      drawRoad(null, mm);
    }
    // framing: the ride and the vehicle, again for a new ride; then it follows gently
    var pts = road.slice();
    if (mm.pos) pts.push(mm.pos);
    if (!pts.length) return;
    if (framedKey !== mm.key && follow) {
      framedKey = mm.key;
      if (pts.length === 1) M.jumpTo({ center: pts[0], zoom: 14, padding: padding() });
      else {
        var b = new ml.LngLatBounds(pts[0], pts[0]);
        pts.forEach(function (p) { b.extend(p); });
        M.fitBounds(b, { padding: padding(), maxZoom: 15, duration: reduce ? 0 : 800 });
      }
    } else if (follow && mm.pos) {
      var pp = M.project(mm.pos), pd = padding(), cw = M.getContainer().clientWidth, chh = M.getContainer().clientHeight;
      if (pp.x < pd.left || pp.x > cw - pd.right || pp.y < pd.top || pp.y > chh - pd.bottom) M.easeTo({ center: mm.pos, padding: pd, duration: reduce ? 0 : 1200 });
    }
  }

  // MARK: the sheet (drag the handle; a tap toggles)
  function setupSheet() {
    var g = $("grab"), card = $("card"), y0 = 0, h0 = 0, moved = false, down = false;
    function setH(px) { D.documentElement.style.setProperty("--h", px + "px"); }
    g.addEventListener("pointerdown", function (e) { down = true; moved = false; y0 = e.clientY; h0 = card.getBoundingClientRect().height; card.className = "sheet drag"; try { g.setPointerCapture(e.pointerId); } catch (x) {} });
    g.addEventListener("pointermove", function (e) {
      if (!down) return;
      if (Math.abs(e.clientY - y0) > 4) moved = true;
      setH(Math.max(W.innerHeight * 0.2, Math.min(W.innerHeight * 0.88, h0 - (e.clientY - y0))));
    });
    g.addEventListener("pointerup", function () {
      if (!down) return;
      down = false; card.className = "sheet";
      var h = card.getBoundingClientRect().height, vh = W.innerHeight, snaps = [0.3, 0.56, 0.88];
      if (!moved) { setH((h < vh * 0.7 ? 0.88 : 0.56) * vh); return; }
      var best = snaps[0];
      snaps.forEach(function (s) { if (Math.abs(s * vh - h) < Math.abs(best * vh - h)) best = s; });
      setH(best * vh);
    });
  }

  // MARK: polling
  function render(s, relayAt) {
    last = s; lastAt = relayAt;
    model = view(s, relayAt, Date.now() / 1000);
    drawCard(model);
    drawMap(model.map);
  }
  function next(ms) { clearTimeout(timer); if (!over && D.visibilityState !== "hidden") timer = setTimeout(poll, ms); }
  function poll() {
    fetch("/live/v1/get?t=" + encodeURIComponent(token), { cache: "no-store" }).then(function (r) {
      if (r.status === 404 || r.status === 410) { forget(); ended("This link has ended"); return null; }
      if (r.status === 429) { next(30000); return null; }
      if (!r.ok) throw new Error("status " + r.status);
      return r.json();
    }).then(function (j) {
      if (!j) return;
      return open(j.data, "hw-live-v1\n").then(function (s) {
        errors = 0;
        setItem("hw-live:" + token, keyText);
        if (keyKept) {
          // (the link as it should be, so it can be copied from here again)
          keyKept = false;
          try { history.replaceState(null, "", location.pathname + "#k=" + keyText); } catch (e) {}
        }
        seen = num(j.seen) || 0;
        takeReplies(j.replies);
        render(s && typeof s === "object" ? s : {}, j.at);
        next(15000);
      }, function () { if (keyKept) forget(); ended("This link’s key doesn’t fit. Ask for the link again.", "Can’t open", "warn"); });
    }).catch(function () {
      errors += 1;
      if (errors >= 2) { var a = $("age"); a.hidden = false; $("ageText").textContent = "can’t reach the trip right now, trying again…"; $("ageDot").className = "dot grey"; }
      next(Math.min(60000, 15000 * errors));
    });
  }

  W.HWLive = { view: view, decode: decode, split: split, keyFrom: keyFrom, music: music, timeline: timeline };
  D.addEventListener("visibilitychange", function () { if (D.visibilityState === "visible" && key && !over) poll(); });
  var raw = keyText ? b64u(keyText) : null;
  if (!W.crypto || !crypto.subtle) { ended("This browser can’t open the trip. Try another browser.", "Can’t open", "warn"); return; }
  if (!/^[A-Za-z0-9_-]{22}$/.test(token) || !raw || raw.length !== 32) { missingKey(); return; }
  try {
    var ua = (W.navigator && navigator.userAgent) || "";
    if (/iPhone|iPad|iPod|Android/.test(ua)) { var oa = $("openApp"); oa.href = "haltewekker://live/" + token + "#k=" + keyText; oa.hidden = false; }
  } catch (e) {}
  setupMessages();
  setupSheet();
  mapInit();
  crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]).then(function (k) {
    key = k; poll();
    ticker = setInterval(function () { if (last && !over) { model = view(last, lastAt, Date.now() / 1000); drawCard(model); } }, 5000);
  }, function () { ended("This browser can’t open the trip. Try another browser.", "Can’t open", "warn"); });
})();
`;
