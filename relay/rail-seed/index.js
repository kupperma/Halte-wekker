// The bundled seed for /rail/v1/side (rail.js): trimmed OpenStreetMap platforms and rails of the stations on the
// Breda ⇄ Tilburg ⇄ 's-Hertogenbosch ⇄ Eindhoven lines, fetched once from Overpass (2026-11-28).
// Map data © OpenStreetMap contributors, ODbL (https://www.openstreetmap.org/copyright).
import bd from "./bd.json" with { type: "json" };
import gz from "./gz.json" with { type: "json" };
import tbr from "./tbr.json" with { type: "json" };
import tb from "./tb.json" with { type: "json" };
import tbu from "./tbu.json" with { type: "json" };
import ot from "./ot.json" with { type: "json" };
import btl from "./btl.json" with { type: "json" };
import vg from "./vg.json" with { type: "json" };
import ht from "./ht.json" with { type: "json" };
import bet from "./bet.json" with { type: "json" };
import ehs from "./ehs.json" with { type: "json" };
import ehv from "./ehv.json" with { type: "json" };

/** Where a line comes in from another side than the stop before is, as the crow flies (not OSM data): a train from
 *  `within` m of `from` uses `via`, a point on its line before the station, for its way. Boxtel: the line from
 *  Tilburg and Oisterwijk (west) joins the Eindhoven line south-east of the station, so those trains come in from the
 *  south-east, like the ones from Best. */
const APPROACH = {
  BTL: [{ from: [51.5821442, 5.193898], within: 10000, via: [51.5713, 5.3326] }],
};

/** Each: {code, name, at: [lat, lon], platforms, rails, approach?, osm (when fetched), attribution}. */
export const SEED = [bd, gz, tbr, tb, tbu, ot, btl, vg, ht, bet, ehs, ehv]
  .map((st) => (APPROACH[st.code] ? { ...st, approach: APPROACH[st.code] } : st));
