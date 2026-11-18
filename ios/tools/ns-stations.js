// Builds App/NSStations.json, the NS stations the app knows by code (for platforms, crowding and train size at any
// station, and the station nearest your home and school for "A train's time"). Nothing is typed by hand: every code,
// UIC number, name and coordinate comes from the open station list of Rijden de Treinen (CC BY 4.0, made from NS's
// own station data): https://opendata.rijdendetreinen.nl/public/stations/
//
//   NODE_USE_ENV_PROXY=1 node tools/ns-stations.js        (from ios/; the env var only behind a proxy)
//
// Only stations in the Netherlands are kept (the app's trips are Dutch; a station abroad isn't asked about).
// Pass another list's file name to use a newer one: node tools/ns-stations.js stations-2025-01.csv

const fs = require('fs');
const path = require('path');

const BASE = 'https://opendata.rijdendetreinen.nl/public/stations/';
const FILE = process.argv[2] || 'stations-2023-09.csv';
const UA = 'Haltewekker-tools/1 (https://github.com/kupperma/Halte-wekker)';
const outFile = path.join(__dirname, '..', 'App', 'NSStations.json');

/** One CSV line into its fields (quoted fields may hold commas; "" is a quote). */
function fields(line) {
  const out = [];
  let cur = '', quoted = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quoted) {
      if (c === '"' && line[i + 1] === '"') { cur += '"'; i++; }
      else if (c === '"') quoted = false;
      else cur += c;
    } else if (c === '"') quoted = true;
    else if (c === ',') { out.push(cur); cur = ''; }
    else cur += c;
  }
  out.push(cur);
  return out;
}

async function main() {
  const r = await fetch(BASE + FILE, { headers: { 'User-Agent': UA } });
  if (!r.ok) throw new Error(`${FILE}: HTTP ${r.status}`);
  const lines = (await r.text()).split(/\r?\n/).filter((l) => l.trim());
  const head = fields(lines[0]);
  const col = (n) => {
    const i = head.indexOf(n);
    if (i < 0) throw new Error(`no column ${n} in ${head.join(',')}`);
    return i;
  };
  const c = { code: col('code'), uic: col('uic'), short: col('name_short'), medium: col('name_medium'), long: col('name_long'),
              country: col('country'), lat: col('geo_lat'), lon: col('geo_lng') };
  const round = (x) => Math.round(Number(x) * 1e5) / 1e5;
  const out = [];
  for (const l of lines.slice(1)) {
    const f = fields(l);
    if (f[c.country] !== 'NL') continue;
    const code = f[c.code].toUpperCase(), uic = f[c.uic];
    const lat = round(f[c.lat]), lon = round(f[c.lon]);
    if (!/^[A-Z]{2,5}$/.test(code) || !/^\d{7}$/.test(uic) || !lat || !lon) { console.warn('skipped', l); continue; }
    const name = f[c.long];
    const names = [...new Set([f[c.medium], f[c.short]])].filter((n) => n && n !== name);
    out.push({ code, uic, name, names, lat, lon });
  }
  out.sort((a, b) => a.code.localeCompare(b.code));
  // one station per line: small diffs when the list is made again
  const json = '[\n' + out.map((s) => JSON.stringify(s)).join(',\n') + '\n]\n';
  fs.writeFileSync(outFile, json);
  console.log(`${out.length} stations from ${FILE} → ${path.relative(process.cwd(), outFile)}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
