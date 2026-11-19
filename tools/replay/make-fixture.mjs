// Makes fixtures/synthetic.json: a made-up export (one phone, one trip of two legs) with made-up vehicles, to show the
// replay works. Nothing in it is real: the road, the buses, the install id and the times are invented.
//   node tools/replay/make-fixture.mjs
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const T0 = Date.UTC(2026, 10, 2, 7, 30, 0) / 1000;      // bus 305 leaves its first stop (made up)
const TZ = 3600;                                          // the phone's clock: UTC+1
const SPEED = 12;                                         // m/s, every bus
const LAT0 = 51.59, LON0 = 4.70;
const round = (x, d) => Math.round(x * 10 ** d) / 10 ** d;

/// A point `east` m east and `north` m north of the made-up road's start.
const at = (east, north) => [round(LAT0 + north / 110540, 6), round(LON0 + east / (111320 * Math.cos(LAT0 * Math.PI / 180)), 6)];
/// The made-up road east (8 km, with a gentle bend), and one north from its end (4 km).
const roadEast = (m) => at(m, 300 * Math.sin(m / 3000));
const END = 8000;
const roadNorth = (m) => { const [lat, lon] = roadEast(END); return [round(lat + m / 110540, 6), lon]; };

/// A bus along a road: a piece per km, leaving `dep`, at SPEED.
function bus(tripId, line, road, length, dep) {
  const pieces = [];
  for (let k = 0; k * 1000 < length; k++) {
    const a = k * 1000, b = Math.min(length, a + 1000);
    const path = [];
    for (let m = a; m <= b; m += 100) path.push(road(m));
    pieces.push({ departure: dep + a / SPEED, arrival: dep + b / SPEED, path });
  }
  return { tripId, line, isTrain: false, realTime: true, pieces };
}

const tracks = [
  bus("synthetic-305-7821", "305", roadEast, END, T0),                 // the one you're on
  bus("synthetic-306-4942", "306", roadEast, END, T0 + 90),            // the same road, 90 s behind
  bus("synthetic-412-0303", "412", (m) => roadEast(END - m), END, T0),  // the same road the other way
  bus("synthetic-400-1111", "400", roadNorth, 4000, T0 + END / SPEED + 60),   // north from the road's end
];

// your points: on 305 east, then (after a minute at the stop) on 400 north; every 3 s, a few metres of GPS noise
const fixes = [];
const noise = (i) => 4 * Math.sin(i * 1.7);
for (let t = T0 + 5; t <= T0 + END / SPEED; t += 3) {
  const m = (t - T0) * SPEED, i = fixes.length;
  const [lat, lon] = roadEast(m);
  fixes.push({ t, lat: round(lat + noise(i) / 110540, 5), lon: round(lon, 5), acc: 6, spd: SPEED, crs: 90, leg: "1/2",
    veh: t < T0 + 130 ? "bus 306·4942" : "bus 305·7821", ride: "5a5a5a5a" });
}
const dep400 = T0 + END / SPEED + 60;
for (let t = dep400 + 5; t <= dep400 + 4000 / SPEED; t += 3) {
  const m = (t - dep400) * SPEED, i = fixes.length;
  const [lat, lon] = roadNorth(m);
  fixes.push({ t, lat: round(lat, 5), lon: round(lon + noise(i) / 69000, 5), acc: 6, spd: SPEED, crs: 0, leg: "2/2",
    veh: "bus 400·1111", ride: "5a5a5a5a" });
}
// as the phone sends them: the first and last 500 m of the trip left out
const dist = (a, b) => Math.hypot((a.lat - b.lat) * 110540, (a.lon - b.lon) * 111320 * Math.cos(a.lat * Math.PI / 180));
const first = fixes[0], last = fixes[fixes.length - 1];
const kept = fixes.filter((f) => dist(f, first) > 500 && dist(f, last) > 500);

const clock = (t) => new Date((t + TZ) * 1000).toISOString().slice(0, 19).replace("T", " ");
const lines = [
  [T0 + 5, "ride start · Home on board, by itself · bus 306·4942 · its stop 40 m from you · leg 1/2"],
  [T0 + 60, "match same bus · n=4 · 306·4942 live 31 s | 305·7821 live 2 s → keep 306·4942"],
  [T0 + 130, "ride hand pick · bus 305·7821 (was 306·4942) · 40 m · gps"],
  [dep400 + 5, "ride start · next leg · bus 400·1111 · its stop 30 m from you · leg 2/2"],
  [dep400 + 4000 / SPEED, "ride arrive · by GPS · 230 m (±6) · leg 330 s old · started 4000 m"],
].map(([t, s]) => {
  const [kind, ...rest] = s.split(" ");
  return kind === "ride" || kind === "match" ? `${clock(t)} ${kind} ${rest.join(" ")}` : `${clock(t)} ride ${s}`;
});

const install = "00000000000000000000000000000001";
const half = Math.floor(kept.length / 2);
const out = {
  note: "Made up: no real ride, road, vehicle or phone. Made by tools/replay/make-fixture.mjs.",
  uploads: [
    { id: 1, install, app: "0.32.0 (123)", at: last.t + 60, lines: lines.slice(0, 3), fixes: kept.slice(0, half), tz: TZ },
    { id: 2, install, app: "0.32.0 (123)", at: last.t + 120, lines: lines.slice(3), fixes: kept.slice(half), tz: TZ },
  ],
  tracks,
};
const file = fileURLToPath(new URL("./fixtures/synthetic.json", import.meta.url));
writeFileSync(file, JSON.stringify(out) + "\n");
console.log(`wrote ${file}: ${kept.length} points, ${lines.length} lines, ${tracks.length} vehicles`);
