// Downloads BRouter routing segments (.rd5, one per 5°×5° tile) into a directory. Node, no dependencies.
// Runs as the one-shot `brouter-segments` service of docker-compose.yml, or by hand:
//   node routing/brouter-segments.mjs                                  # default area, into ./segments4
//   BROUTER_TILES="W5_N40 E0_N40" BROUTER_SEGMENTS_DIR=/srv/segments4 node routing/brouter-segments.mjs
// Settings (environment):
//   BROUTER_TILES         tile names, space/comma separated (e.g. "W5_N40 E0_N40"); wins over the bbox
//   BROUTER_BBOX          minLon,minLat,maxLon,maxLat; default: peninsular Spain and the Balearic Islands
//   BROUTER_SEGMENTS_DIR  target directory (default ./segments4)
//   BROUTER_SEGMENTS_URL  where the tiles live (default: the public brouter.de mirror)
//   BROUTER_SEGMENTS_UPDATE=true  re-check tiles already on disk and fetch the ones that changed
// Tiles already on disk are kept as they are unless BROUTER_SEGMENTS_UPDATE is set; nothing is deleted.
import { createWriteStream, existsSync, mkdirSync, renameSync, rmSync, statSync, utimesSync } from 'node:fs';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { pathToFileURL } from 'node:url';

export const DEFAULT_BBOX = '-9.5,35.8,4.5,43.9';   // peninsular Spain + Balearics -> 6 tiles, about 410 MB
export const DEFAULT_URL = 'https://brouter.de/brouter/segments4/';
const TILE_TIMEOUT_MS = 30 * 60 * 1000;               // per tile; the largest are a few hundred MB

// Tile name of the 5° cell whose south-west corner is (lon, lat): (-5, 40) -> "W5_N40".
export function tileName(lon, lat) {
  return `${lon < 0 ? 'W' : 'E'}${Math.abs(lon)}_${lat < 0 ? 'S' : 'N'}${Math.abs(lat)}`;
}

// Every tile that a "minLon,minLat,maxLon,maxLat" box touches.
export function tilesForBbox(bbox) {
  const v = String(bbox).split(',').map((s) => Number(s.trim()));
  const [minLon, minLat, maxLon, maxLat] = v;
  if (v.length !== 4 || v.some(Number.isNaN) || minLon >= maxLon || minLat >= maxLat
      || minLon < -180 || maxLon > 180 || minLat < -90 || maxLat > 90) {
    throw new Error(`invalid bbox "${bbox}": expected minLon,minLat,maxLon,maxLat in degrees`);
  }
  const tiles = [];
  for (let lat = Math.floor(minLat / 5) * 5; lat < maxLat; lat += 5) {
    for (let lon = Math.floor(minLon / 5) * 5; lon < maxLon; lon += 5) tiles.push(tileName(lon, lat));
  }
  return tiles;
}

// "W5_N40, E0_N40" -> ["W5_N40", "E0_N40"], checking each name is a real 5° tile.
export function parseTiles(list) {
  const tiles = String(list).split(/[\s,]+/).filter(Boolean).map((t) => t.replace(/\.rd5$/i, '').toUpperCase());
  for (const t of tiles) {
    const m = /^([EW])(\d{1,3})_([NS])(\d{1,2})$/.exec(t);
    const lon = m && (m[1] === 'W' ? -1 : 1) * Number(m[2]);
    const lat = m && (m[3] === 'S' ? -1 : 1) * Number(m[4]);
    if (!m || lon % 5 || lat % 5 || lon < -180 || lon > 175 || lat < -90 || lat > 85 || tileName(lon, lat) !== t) {
      throw new Error(`invalid tile "${t}": expected names like W5_N40 or E0_N40 (5° steps)`);
    }
  }
  return [...new Set(tiles)];
}

const mb = (n) => `${(n / 1e6).toFixed(1)} MB`;

// Fetches one tile into dir. Returns 'downloaded' | 'kept' | 'unchanged' | 'missing'.
async function fetchTile(tile, { dir, baseUrl, update }) {
  const file = join(dir, `${tile}.rd5`);
  const have = existsSync(file);
  if (have && !update) return 'kept';
  const headers = have ? { 'if-modified-since': statSync(file).mtime.toUTCString() } : {};
  const res = await fetch(new URL(`${tile}.rd5`, baseUrl), { headers, signal: AbortSignal.timeout(TILE_TIMEOUT_MS) });
  if (res.status === 304) return 'unchanged';
  if (res.status === 404) return 'missing';                  // open sea: brouter.de has no tile there
  if (!res.ok) throw new Error(`${tile}: HTTP ${res.status}`);

  const part = `${file}.part`;                                // never leave a half tile under the real name
  const expected = Number(res.headers.get('content-length')) || null;
  const started = Date.now();
  try {
    await pipeline(Readable.fromWeb(res.body), createWriteStream(part));
    const size = statSync(part).size;
    if (expected && size !== expected) throw new Error(`${tile}: got ${size} of ${expected} bytes`);
    const modified = Date.parse(res.headers.get('last-modified'));
    if (modified) utimesSync(part, new Date(), new Date(modified));   // basis for the next If-Modified-Since
    renameSync(part, file);
    console.log(`  ${tile}: ${mb(size)} in ${((Date.now() - started) / 1000).toFixed(1)} s`);
    return 'downloaded';
  } catch (e) {
    rmSync(part, { force: true });
    throw e;
  }
}

export async function main(env = process.env) {
  const dir = env.BROUTER_SEGMENTS_DIR || 'segments4';
  const baseUrl = (env.BROUTER_SEGMENTS_URL || DEFAULT_URL).replace(/\/?$/, '/');
  const update = /^(1|true|yes|on)$/i.test(env.BROUTER_SEGMENTS_UPDATE || '');
  const tiles = env.BROUTER_TILES ? parseTiles(env.BROUTER_TILES) : tilesForBbox(env.BROUTER_BBOX || DEFAULT_BBOX);
  mkdirSync(dir, { recursive: true });
  console.log(`BRouter segments: ${tiles.join(' ')} -> ${dir}${update ? ' (update)' : ''}`);

  const count = {};
  let failed = 0;
  for (const tile of tiles) {
    try {
      const r = await fetchTile(tile, { dir, baseUrl, update });
      count[r] = (count[r] || 0) + 1;
      if (r === 'missing') console.warn(`  ${tile}: not on the server (sea only?), skipped`);
    } catch (e) {
      // a tile already on disk still works: a failed update is only a warning
      if (existsSync(join(dir, `${tile}.rd5`))) console.warn(`  ${tile}: update failed, keeping the old one (${e.message})`);
      else { console.error(`  ${tile}: ${e.message}`); failed++; }
    }
  }
  console.log(`done: ${Object.entries(count).map(([k, v]) => `${v} ${k}`).join(', ') || 'nothing to do'}${failed ? `, ${failed} failed` : ''}`);
  return failed ? 1 : 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().then((code) => { process.exitCode = code; }, (e) => { console.error(e.message); process.exitCode = 1; });
}
