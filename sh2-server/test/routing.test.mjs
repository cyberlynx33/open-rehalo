// /routing/* proxy: e2e over real HTTP against fake BRouter/Valhalla upstreams (node:http, in-process).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request } from 'node:http';
import { tmpdir } from 'node:os';
import { mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { createApp, UserStore } from '../src/server.mjs';

const secret = 'test-secret';
const listen = async (srv) => { await new Promise((r) => srv.listen(0, '127.0.0.1', r)); return `http://127.0.0.1:${srv.address().port}`; };
const store = () => new UserStore(join(mkdtempSync(join(tmpdir(), 'sh2route-')), 'users.json'));

// The exact request the app's BRouter client sends (native API, unescaped '|' and ',').
const BROUTER_QUERY = 'lonlats=-3.7038,40.4168|-3.6883,40.4531&profile=gravel&alternativeidx=0&format=geojson&timode=3';
const GEOJSON = JSON.stringify({
  type: 'FeatureCollection',
  features: [{ type: 'Feature', properties: { 'track-length': '4321', voicehints: [[3, 2, 0, 120, -90]] },
    geometry: { type: 'LineString', coordinates: [[-3.7038, 40.4168, 655], [-3.6883, 40.4531, 690]] } }],
});

// Fake BRouter: answers like RouteServer (no Content-Length, Connection: close) and records requests.
const seen = [];
const brouter = createServer((req, res) => {
  seen.push({ method: req.method, url: req.url, headers: req.headers });
  if (req.url === '/robots.txt') { res.writeHead(200, { 'content-type': 'text/plain' }); return res.end('User-agent: *\nDisallow: /\n'); }
  if (req.url.startsWith('/brouter?') && req.url.includes('profile=nosuch')) {
    res.writeHead(400, { 'content-type': 'text/plain; charset=utf-8', connection: 'close' });
    return res.end('profile nosuch does not exist\n');
  }
  if (req.url.startsWith('/brouter?')) {
    res.writeHead(200, { 'content-type': 'application/vnd.geo+json; charset=utf-8', connection: 'close', 'access-control-allow-origin': '*' });
    return res.end(GEOJSON);
  }
  if (req.url === '/hang') { req.on('close', () => { brouter.hungClosed = true; }); return; }   // never answers
  if (req.url === '/big-declared') { res.writeHead(200, { 'content-length': 4096 }); return res.end(Buffer.alloc(4096)); }
  if (req.url === '/big-streamed') {
    res.writeHead(200, { 'content-type': 'application/octet-stream' });
    let n = 0;
    const tick = setInterval(() => { res.write(Buffer.alloc(512)); if (++n === 8 || res.destroyed) { clearInterval(tick); res.end(); } }, 5);
    return;
  }
  res.writeHead(404, { 'content-type': 'text/plain' });
  res.end('not found');
});

// Fake Valhalla: /status and an echoing POST /route.
const valhalla = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    if (req.url === '/status') {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ version: '3.9.1', tileset_last_modified: 1763000000 }));
    }
    if (req.url.startsWith('/route')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ trip: { status: 0 }, echo: Buffer.concat(chunks).toString(), url: req.url }));
    }
    res.writeHead(404); res.end();
  });
});

let brouterUrl, valhallaUrl, closedUrl;
const apps = {};
const bases = {};
async function start(name, opts) {
  apps[name] = createApp({ store: opts.store ?? store(), secret, routing: opts.routing });
  bases[name] = await listen(apps[name]);
}

before(async () => {
  brouterUrl = await listen(brouter);
  valhallaUrl = await listen(valhalla);
  const gone = createServer();                       // a port that refuses connections
  closedUrl = await listen(gone);
  await new Promise((r) => gone.close(r));
  await start('main', { routing: { brouterUrl, valhallaUrl, timeoutMs: 300, maxResponseBytes: 2048, maxRequestBytes: 1024 } });
  await start('none', { routing: {} });
  await start('down', { routing: { brouterUrl: closedUrl, valhallaUrl: `${valhallaUrl}/` } });
  await start('auth', { routing: { brouterUrl, auth: true } });
});
after(() => {
  for (const s of [brouter, valhalla, ...Object.values(apps)]) { s.closeAllConnections(); s.close(); }
});

test('routing: BRouter native API through the proxy, prefix stripped and query byte-for-byte', async () => {
  seen.length = 0;
  const r = await fetch(`${bases.main}/routing/brouter/brouter?${BROUTER_QUERY}`);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('content-type'), 'application/vnd.geo+json; charset=utf-8');
  assert.equal(r.headers.get('access-control-allow-origin'), '*');
  const j = await r.json();
  assert.deepEqual(j.features[0].properties.voicehints, [[3, 2, 0, 120, -90]]);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, `/brouter?${BROUTER_QUERY}`);   // what the app would send to BRouter's own port
  assert.equal(seen[0].headers.host, new URL(brouterUrl).host);
  assert.ok(seen[0].headers['x-forwarded-for']);
});

test('routing: percent-encoded query is forwarded untouched too', async () => {
  seen.length = 0;
  const q = 'lonlats=-3.7038%2C40.4168%7C-3.6883%2C40.4531&profile=trekking&alternativeidx=0&format=geojson';
  assert.equal((await fetch(`${bases.main}/routing/brouter/brouter?${q}`)).status, 200);
  assert.equal(seen[0].url, `/brouter?${q}`);
});

test('routing: upstream errors pass through with their status and body', async () => {
  const r = await fetch(`${bases.main}/routing/brouter/brouter?lonlats=1,2|3,4&profile=nosuch`);
  assert.equal(r.status, 400);
  assert.match(await r.text(), /profile nosuch does not exist/);
});

test('routing: Valhalla POST /route body is streamed to the engine', async () => {
  const body = JSON.stringify({ locations: [{ lat: 42.50, lon: 1.52 }, { lat: 42.54, lon: 1.58 }], costing: 'bicycle' });
  const r = await fetch(`${bases.main}/routing/valhalla/route`, { method: 'POST', headers: { 'content-type': 'application/json' }, body });
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.echo, body);
  assert.equal(j.url, '/route');
});

test('routing: Expect: 100-continue (curl, bodies over 1 KB) is answered here, not forwarded', async () => {
  const body = JSON.stringify({ costing: 'bicycle', pad: 'x'.repeat(900) });
  const r = await new Promise((resolve, reject) => {
    const u = new URL(`${bases.main}/routing/valhalla/route`);
    const req = request({ hostname: u.hostname, port: u.port, path: u.pathname, method: 'POST',
      headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body), expect: '100-continue' } }, resolve);
    req.on('continue', () => req.end(body));
    req.on('error', reject);
  });
  assert.equal(r.statusCode, 200);
  const chunks = [];
  for await (const c of r) chunks.push(c);
  assert.equal(JSON.parse(Buffer.concat(chunks)).echo, body);
});

test('routing: Valhalla GET with ?json= and an engine URL with a trailing slash', async () => {
  const q = `json=${encodeURIComponent('{"costing":"bicycle"}')}`;
  const j = await (await fetch(`${bases.down}/routing/valhalla/route?${q}`)).json();
  assert.equal(j.url, `/route?${q}`);
});

test('routing: engine not configured -> 503 with a clear JSON error', async () => {
  for (const engine of ['brouter', 'valhalla']) {
    const r = await fetch(`${bases.none}/routing/${engine}/brouter?${BROUTER_QUERY}`);
    assert.equal(r.status, 503);
    assert.equal(r.headers.get('content-type'), 'application/json');
    const j = await r.json();
    assert.equal(j.engine, engine);
    assert.match(j.error, /not configured/);
    assert.equal(j.hint, engine === 'brouter' ? 'set SH2_BROUTER_URL' : 'set SH2_VALHALLA_URL');
  }
});

test('routing: unknown /routing path -> 404, the rest of the API is untouched', async () => {
  assert.equal((await fetch(`${bases.main}/routing/osrm/route`)).status, 404);
  assert.equal((await fetch(`${bases.main}/routing`)).status, 404);
  assert.equal((await fetch(`${bases.main}/health`)).status, 200);
});

test('routing: /routing/status reports configured engines and whether they answer', async () => {
  let j = await (await fetch(`${bases.main}/routing/status`)).json();
  assert.equal(j.engines.brouter.configured, true);
  assert.equal(j.engines.brouter.reachable, true);
  assert.equal(j.engines.brouter.path, '/routing/brouter');
  assert.equal(j.engines.valhalla.reachable, true);
  assert.equal(j.engines.valhalla.version, '3.9.1');
  assert.equal(typeof j.engines.valhalla.latency_ms, 'number');
  assert.equal(JSON.stringify(j).includes('127.0.0.1'), false);   // upstream addresses stay private

  j = await (await fetch(`${bases.none}/routing/status`)).json();
  assert.deepEqual(j.engines, { brouter: { configured: false, path: '/routing/brouter' }, valhalla: { configured: false, path: '/routing/valhalla' } });

  j = await (await fetch(`${bases.down}/routing/status`)).json();
  assert.equal(j.engines.brouter.configured, true);
  assert.equal(j.engines.brouter.reachable, false);
  assert.equal(j.engines.brouter.error, 'ECONNREFUSED');
  assert.equal(j.engines.valhalla.reachable, true);
});

test('routing: engine down -> 502', async () => {
  const r = await fetch(`${bases.down}/routing/brouter/brouter?${BROUTER_QUERY}`);
  assert.equal(r.status, 502);
  const j = await r.json();
  assert.equal(j.engine, 'brouter');
  assert.equal(j.detail, 'ECONNREFUSED');
});

test('routing: slow engine -> 504 after the timeout, and the upstream request is dropped', async () => {
  brouter.hungClosed = false;
  const t0 = Date.now();
  const r = await fetch(`${bases.main}/routing/brouter/hang`);
  assert.equal(r.status, 504);
  assert.ok(Date.now() - t0 < 2000);
  assert.match((await r.json()).error, /did not answer/);
  await new Promise((res) => setTimeout(res, 50));
  assert.equal(brouter.hungClosed, true);
});

test('routing: client going away drops the upstream request', async () => {
  brouter.hungClosed = false;
  await assert.rejects(fetch(`${bases.main}/routing/brouter/hang`, { signal: AbortSignal.timeout(50) }));
  await new Promise((res) => setTimeout(res, 100));
  assert.equal(brouter.hungClosed, true);
});

test('routing: response size cap (declared -> 502, streamed -> cut off)', async () => {
  const r = await fetch(`${bases.main}/routing/brouter/big-declared`);
  assert.equal(r.status, 502);
  assert.match((await r.json()).error, /over 2048 bytes/);
  // no Content-Length (like BRouter): headers are already out, so the stream is cut short
  await assert.rejects(async () => { await (await fetch(`${bases.main}/routing/brouter/big-streamed`)).arrayBuffer(); });
});

test('routing: request body size cap -> 413', async () => {
  let r = await fetch(`${bases.main}/routing/valhalla/route`, { method: 'POST', body: 'x'.repeat(2000) });
  assert.equal(r.status, 413);
  // chunked, no Content-Length: counted while streaming
  r = await new Promise((resolve, reject) => {
    const u = new URL(`${bases.main}/routing/valhalla/route`);
    const req = request({ hostname: u.hostname, port: u.port, path: u.pathname, method: 'POST' }, resolve);
    req.on('error', reject);
    req.write('x'.repeat(800));
    setTimeout(() => req.end('x'.repeat(800)), 20);
  });
  assert.equal(r.statusCode, 413);
  r.resume();
});

test('routing: SH2_ROUTING_AUTH requires the user JWT and never forwards it', async () => {
  let r = await fetch(`${bases.auth}/routing/brouter/brouter?${BROUTER_QUERY}`);
  assert.equal(r.status, 401);
  assert.equal((await fetch(`${bases.auth}/routing/status`)).status, 401);
  assert.equal((await fetch(`${bases.auth}/routing/brouter/brouter?${BROUTER_QUERY}`, { headers: { 'x-access-token': 'nope' } })).status, 401);

  const { access_jwt, refresh_jwt } = await (await fetch(`${bases.auth}/auth/local/signup`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: 'r@b.com', password: 'pw' }),
  })).json();
  assert.equal((await fetch(`${bases.auth}/routing/status`, { headers: { 'x-access-token': refresh_jwt } })).status, 401);

  seen.length = 0;
  r = await fetch(`${bases.auth}/routing/brouter/brouter?${BROUTER_QUERY}`, { headers: { 'x-access-token': access_jwt } });
  assert.equal(r.status, 200);
  assert.ok((await r.json()).features);
  r = await fetch(`${bases.auth}/routing/brouter/brouter?${BROUTER_QUERY}`, { headers: { authorization: `Bearer ${access_jwt}` } });
  assert.equal(r.status, 200);
  await r.arrayBuffer();
  assert.equal(seen.length, 2);
  for (const s of seen) {
    assert.equal(s.headers['x-access-token'], undefined);
    assert.equal(s.headers.authorization, undefined);
  }
  // auth off (default): no token needed
  assert.equal((await fetch(`${bases.main}/routing/status`)).status, 200);
});

test('routing: an invalid engine URL fails at startup', () => {
  assert.throws(() => createApp({ store: store(), secret, routing: { brouterUrl: 'brouter:17777' } }), /SH2_BROUTER_URL must be an http\(s\) URL/);
});
