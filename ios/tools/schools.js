// Builds App/Schools.json, the schools the first-run setup lists, from tools/schools-seed.json: every campus is
// geocoded with Transitous (/v1/geocode), never typed by hand. A person checks tools/schools-review.txt afterwards
// (what each campus was matched to, and what was left out).
//
//   NODE_USE_ENV_PROXY=1 node tools/schools.js        (from ios/; the env var only behind a proxy)
//
// A campus is kept only when a result is in the Netherlands, in the campus's town (its municipality or place, not a
// province of the same name; a result without those within 4 km of the town), and its name (or street) contains one
// of the campus's or else the school's `match` words. Places beat addresses, addresses beat stops. A school with no
// campus found is left out. One request a second (Transitous is run by volunteers).

const fs = require('fs');
const path = require('path');

const BASE = 'https://api.transitous.org/api/v1/geocode';
const UA = 'Haltewekker-tools/1 (https://github.com/kupperma/Halte-wekker)';
const here = __dirname;
const seedFile = path.join(here, 'schools-seed.json');
const outFile = path.join(here, '..', 'App', 'Schools.json');
const reviewFile = path.join(here, 'schools-review.txt');

const fold = (s) => (s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[’‘]/g, "'").toLowerCase().trim();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rad = (d) => (d * Math.PI) / 180;
function metres(a, b) {
  const x = rad(b.lon - a.lon) * Math.cos(rad((a.lat + b.lat) / 2)), y = rad(b.lat - a.lat);
  return Math.sqrt(x * x + y * y) * 6371000;
}

let last = 0;
async function geocode(text, near) {
  const wait = 1000 - (Date.now() - last);
  if (wait > 0) await sleep(wait);
  last = Date.now();
  const u = new URL(BASE);
  u.searchParams.set('text', text);
  u.searchParams.set('numResults', '20');
  if (near) u.searchParams.set('place', `${near.lat},${near.lon}`);
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await fetch(u, { headers: { 'User-Agent': UA } });
      if (r.status === 429 || r.status >= 500) { await sleep(5000); continue; }
      const j = await r.json();
      return Array.isArray(j) ? j : [];
    } catch (e) {
      await sleep(3000);
    }
  }
  return [];
}

// the municipality (admin level 8) and the place (10), never the province (4) that can share a town's name
const townAreas = (r) => (r.areas || []).filter((a) => (a.adminLevel || 0) >= 7).map((a) => fold(a.name));
const rank = { PLACE: 0, ADDRESS: 1, STOP: 2 };
// a school's office, canteen or car park isn't where classes are
const avoid = ['bestuursbureau', 'kantine', 'hairstyling', 'parkeer', 'parking', 'auto '];
const cityAliases = { "den haag": ["'s-gravenhage", 'den haag'], "'s-hertogenbosch": ["'s-hertogenbosch", 'den bosch'] };
const cityWords = (c) => cityAliases[fold(c)] || [fold(c)];

const cities = new Map();
async function city(name) {
  if (cities.has(name)) return cities.get(name);
  const words = cityWords(name);
  const list = (await geocode(name)).filter((r) => r.country === 'NL');
  const named = list.filter((r) => r.type === 'PLACE' && words.includes(fold(r.name)));
  const hit = named.find((r) => townAreas(r).some((a) => words.includes(a))) || named[0] || list.find((r) => r.type === 'PLACE') || null;
  const c = hit ? { lat: hit.lat, lon: hit.lon, name: hit.name } : null;
  cities.set(name, c);
  return c;
}

function accept(r, campus, centre, match) {
  if (r.country !== 'NL') return false;
  const words = cityWords(campus.city);
  const towns = townAreas(r);
  const inCity = towns.length ? towns.some((a) => words.includes(a)) : !!centre && metres(centre, r) < 4000;
  if (!inCity) return false;
  const text = fold(`${r.name} ${r.street || ''} `);
  if (avoid.some((w) => text.includes(w))) return false;
  return match.some((m) => text.includes(fold(m)));
}

async function main() {
  const seed = JSON.parse(fs.readFileSync(seedFile, 'utf8'));
  const out = [], review = [];
  for (const s of seed) {
    const campuses = [];
    for (const c of s.campuses) {
      const centre = await city(c.city);
      let found = null, asked = null;
      for (const q of c.q || [s.name]) {
        const hits = (await geocode(q, centre)).filter((r) => accept(r, c, centre, c.match || s.match || [fold(s.short)]));
        hits.sort((a, b) => (rank[a.type] ?? 3) - (rank[b.type] ?? 3));
        if (hits.length) { found = hits[0]; asked = q; break; }
      }
      if (found) {
        const lat = Math.round(found.lat * 1e5) / 1e5, lon = Math.round(found.lon * 1e5) / 1e5;
        campuses.push({ name: c.name, city: c.city.replace("'s-", '’s-'), lat, lon });
        const d = centre ? ` · ${(metres(centre, found) / 1000).toFixed(1)} km from ${centre.name}` : '';
        review.push(`ok   ${s.id} / ${c.name}: "${asked}" → ${found.type} "${found.name}" ${lat},${lon}${d}`);
      } else {
        review.push(`MISS ${s.id} / ${c.name} (${c.city}): nothing matched ${JSON.stringify(c.q)}`);
      }
    }
    if (campuses.length) out.push({ id: s.id, name: s.name, short: s.short, aliases: s.aliases || [], campuses });
    else review.push(`LEFT OUT ${s.id}: no campus found`);
    process.stdout.write(`${s.id}: ${campuses.length}/${s.campuses.length}\n`);
  }
  fs.writeFileSync(outFile, JSON.stringify(out, null, 1) + '\n');
  fs.writeFileSync(reviewFile, `Schools.json, made by tools/schools.js on ${new Date().toISOString().slice(0, 10)} from Transitous /v1/geocode.\n` +
    `${out.length} schools, ${out.reduce((n, s) => n + s.campuses.length, 0)} campuses. Check each line; fix the seed's queries, not the output.\n\n` +
    review.join('\n') + '\n');
  console.log(`${out.length} schools written to ${path.relative(process.cwd(), outFile)}; review in ${path.relative(process.cwd(), reviewFile)}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
