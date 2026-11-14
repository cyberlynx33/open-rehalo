// routing/brouter-segments.mjs: tile selection, plus downloads against a fake tile server (node:http).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DEFAULT_BBOX, main, parseTiles, tileName, tilesForBbox } from '../routing/brouter-segments.mjs';

test('segments: tile names follow the south-west corner', () => {
  assert.equal(tileName(-5, 40), 'W5_N40');
  assert.equal(tileName(0, 40), 'E0_N40');
  assert.equal(tileName(-10, -35), 'W10_S35');
});

test('segments: default bbox = peninsular Spain + Balearics in 6 tiles', () => {
  assert.deepEqual(tilesForBbox(DEFAULT_BBOX).sort(), ['E0_N35', 'E0_N40', 'W10_N35', 'W10_N40', 'W5_N35', 'W5_N40']);
  assert.deepEqual(tilesForBbox('-3.8,40.3,-3.6,40.5'), ['W5_N40']);              // Madrid
  assert.deepEqual(tilesForBbox('1.4,42.4,1.8,42.7'), ['E0_N40']);                // Andorra
  assert.deepEqual(tilesForBbox('0,40,5,45'), ['E0_N40']);                        // edges don't spill over
  assert.throws(() => tilesForBbox('1,2,3'), /invalid bbox/);
  assert.throws(() => tilesForBbox('5,40,0,45'), /invalid bbox/);
});

test('segments: tile lists are checked', () => {
  assert.deepEqual(parseTiles('W5_N40, e0_n40 W5_N40.rd5'), ['W5_N40', 'E0_N40']);
  for (const bad of ['W3_N40', 'X5_N40', 'E180_N40', 'W5_N90', 'W05_N40', '../E0_N40']) {
    assert.throws(() => parseTiles(bad), /invalid tile/, bad);
  }
});

// Fake mirror: W5_N40 exists (with Last-Modified), E0_N40 changes once, W10_N40 is open sea (404).
const served = [];
let e0Version = 1;
const mirror = createServer((req, res) => {
  served.push(`${req.method} ${req.url}${req.headers['if-modified-since'] ? ' (conditional)' : ''}`);
  const lastModified = new Date(Date.UTC(2026, 10, e0Version)).toUTCString();
  if (req.url === '/segments4/W5_N40.rd5') {
    if (req.headers['if-modified-since']) { res.writeHead(304); return res.end(); }
    res.writeHead(200, { 'content-length': 5, 'last-modified': lastModified });
    return res.end('w5n40');
  }
  if (req.url === '/segments4/E0_N40.rd5') {
    if (req.headers['if-modified-since'] && Date.parse(req.headers['if-modified-since']) >= Date.parse(lastModified)) {
      res.writeHead(304); return res.end();
    }
    res.writeHead(200, { 'content-length': 6, 'last-modified': lastModified });
    return res.end(`e0n40${e0Version}`);
  }
  if (req.url === '/segments4/E5_N40.rd5') {            // promises more than it sends
    res.writeHead(200, { 'content-length': 100 });
    res.write('short');
    return res.destroy();
  }
  res.writeHead(404); res.end();
});
let base;
before(async () => {
  await new Promise((r) => mirror.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${mirror.address().port}/segments4`;   // no trailing slash on purpose
});
after(() => mirror.close());

const quiet = async (fn) => {
  const { log, warn, error } = console;
  console.log = console.warn = console.error = () => {};
  try { return await fn(); } finally { Object.assign(console, { log, warn, error }); }
};

test('segments: download, keep what is there, update only what changed', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'sh2seg-'));
  const env = { BROUTER_SEGMENTS_DIR: dir, BROUTER_SEGMENTS_URL: base, BROUTER_TILES: 'W5_N40 E0_N40 W10_N40' };

  served.length = 0;
  assert.equal(await quiet(() => main(env)), 0);                  // a sea tile (404) is not an error
  assert.deepEqual(readdirSync(dir).sort(), ['E0_N40.rd5', 'W5_N40.rd5']);
  assert.equal(readFileSync(join(dir, 'E0_N40.rd5'), 'utf8'), 'e0n401');
  assert.equal(statSync(join(dir, 'W5_N40.rd5')).mtime.getTime(), Date.UTC(2026, 10, 1));

  served.length = 0;                                                // second start: no download at all
  assert.equal(await quiet(() => main(env)), 0);
  assert.deepEqual(served, ['GET /segments4/W10_N40.rd5']);

  e0Version = 2;                                                    // the mirror rebuilt E0_N40
  served.length = 0;
  assert.equal(await quiet(() => main({ ...env, BROUTER_SEGMENTS_UPDATE: 'true' })), 0);
  assert.deepEqual(served, ['GET /segments4/W5_N40.rd5 (conditional)', 'GET /segments4/E0_N40.rd5 (conditional)', 'GET /segments4/W10_N40.rd5']);
  assert.equal(readFileSync(join(dir, 'E0_N40.rd5'), 'utf8'), 'e0n402');
});

test('segments: a truncated download fails and leaves nothing behind; an old tile survives a failed update', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'sh2seg-'));
  const env = { BROUTER_SEGMENTS_DIR: dir, BROUTER_SEGMENTS_URL: base, BROUTER_TILES: 'E5_N40' };
  assert.equal(await quiet(() => main(env)), 1);
  assert.deepEqual(readdirSync(dir), []);

  writeFileSync(join(dir, 'E5_N40.rd5'), 'old');
  assert.equal(await quiet(() => main({ ...env, BROUTER_SEGMENTS_UPDATE: '1' })), 0);
  assert.equal(readFileSync(join(dir, 'E5_N40.rd5'), 'utf8'), 'old');
});
