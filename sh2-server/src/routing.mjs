// Optional reverse proxy to self-hosted bike routing engines. node:http/https, no dependencies.
//   /routing/brouter/*   -> SH2_BROUTER_URL, prefix stripped (/routing/brouter/brouter?… -> <url>/brouter?…)
//   /routing/valhalla/*  -> SH2_VALHALLA_URL (/routing/valhalla/route -> <url>/route)
//   /routing/status      -> which engines are configured and whether they answer
// The engines' native APIs pass through untouched: the query string is forwarded byte for byte and
// bodies are streamed both ways (never buffered), capped in size and time.
import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { Transform, pipeline } from 'node:stream';

export const ROUTING_DEFAULTS = {
  timeoutMs: 120_000,             // whole exchange; keep BRouter's -DmaxRunningTime at or below it
  maxResponseBytes: 16 * 1024 * 1024,
  maxRequestBytes: 1024 * 1024,   // Valhalla POST bodies, BRouter profile uploads
  statusTimeoutMs: 3000,
};

const ENGINES = {
  brouter: { env: 'SH2_BROUTER_URL', probe: '/robots.txt' },  // RouteServer answers it without routing
  valhalla: { env: 'SH2_VALHALLA_URL', probe: '/status' },
};

// Never forwarded either way (RFC 9110 §7.6.1; Node already answered any Expect: 100-continue),
// plus the caller's credentials, which stay here.
const HOP_BY_HOP = new Set(['connection', 'keep-alive', 'proxy-connection', 'proxy-authenticate',
  'proxy-authorization', 'te', 'trailer', 'transfer-encoding', 'upgrade', 'host', 'expect']);
const CREDENTIALS = new Set(['x-access-token', 'authorization', 'x-consumer-token', 'cookie']);

class TooLarge extends Error {}

function json(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

// Counts bytes on their way through and fails the pipeline past `max`.
function capped(max) {
  let seen = 0;
  return new Transform({
    transform(chunk, _enc, cb) {
      seen += chunk.length;
      cb(seen > max ? new TooLarge(`more than ${max} bytes`) : null, chunk);
    },
  });
}

function parseUpstream(name, raw) {
  if (!raw) return null;
  let url = null;
  try { url = new URL(raw); } catch {}
  if (!url || !/^https?:$/.test(url.protocol)) {
    throw new Error(`${ENGINES[name].env} must be an http(s) URL, got "${raw}"`);
  }
  return {
    request: url.protocol === 'https:' ? httpsRequest : httpRequest,
    protocol: url.protocol,
    hostname: url.hostname.replace(/^\[|\]$/g, ''),   // IPv6 literal without brackets
    port: url.port || undefined,
    host: url.host,
    base: url.pathname.replace(/\/+$/, ''),           // engine behind a path prefix, if any
  };
}

/**
 * Builds the /routing/* handler. `brouterUrl`/`valhallaUrl` unset = that engine answers 503.
 * Returns { handles(pathname), handle(req, res, url) }; authentication is the caller's job.
 */
export function createRouting({ brouterUrl, valhallaUrl, ...limits } = {}) {
  const opts = { ...ROUTING_DEFAULTS };
  for (const [k, v] of Object.entries(limits)) if (Number(v) > 0) opts[k] = Number(v);   // else the default
  const upstreams = { brouter: parseUpstream('brouter', brouterUrl), valhalla: parseUpstream('valhalla', valhallaUrl) };

  function forward(name, up, req, res, path) {
    const q = req.url.indexOf('?');
    const query = q >= 0 ? req.url.slice(q) : '';     // raw: BRouter's lonlats use unescaped '|' and ','
    const headers = {};
    for (const [k, v] of Object.entries(req.headers)) {
      if (!HOP_BY_HOP.has(k) && !CREDENTIALS.has(k)) headers[k] = v;
    }
    headers.host = up.host;
    const peer = req.socket.remoteAddress;
    headers['x-forwarded-for'] = req.headers['x-forwarded-for'] ? `${req.headers['x-forwarded-for']}, ${peer}` : peer;

    const declared = Number(req.headers['content-length']);
    if (declared > opts.maxRequestBytes) {
      return json(res, 413, { error: `request body over ${opts.maxRequestBytes} bytes`, engine: name });
    }

    let done = false;
    const fail = (status, body) => {                  // once; before headers a JSON error, after them a cut
      if (done) return;
      done = true;
      clearTimeout(timer);
      upReq.destroy();
      req.resume();                                   // a paused upload drains into the void
      if (!res.headersSent) json(res, status, { ...body, engine: name });
      else res.destroy();
    };
    const timer = setTimeout(() => fail(504, { error: `routing engine did not answer within ${opts.timeoutMs} ms` }), opts.timeoutMs);
    res.on('close', () => {                           // finished, or the client went away
      clearTimeout(timer);
      if (!res.writableFinished) upReq.destroy();
    });

    const upReq = up.request({
      protocol: up.protocol, hostname: up.hostname, port: up.port,
      method: req.method, path: up.base + path + query, headers,
    }, (upRes) => {
      if (done) return upRes.resume();
      if (Number(upRes.headers['content-length']) > opts.maxResponseBytes) {
        upRes.resume();
        return fail(502, { error: `routing engine response over ${opts.maxResponseBytes} bytes` });
      }
      const out = {};
      for (const [k, v] of Object.entries(upRes.headers)) if (!HOP_BY_HOP.has(k)) out[k] = v;
      res.writeHead(upRes.statusCode, out);
      pipeline(upRes, capped(opts.maxResponseBytes), res, (err) => {
        if (err) fail(502, { error: 'routing engine response cut off' });
        else { done = true; clearTimeout(timer); }
      });
    });
    upReq.on('error', (e) => fail(502, { error: 'routing engine unreachable', detail: e.code || e.message }));

    // Request body by hand rather than pipeline(): a pipeline error would destroy `req`, and with it the
    // socket the 413 has to go out on.
    let sent = 0;
    req.on('data', (chunk) => {
      if (done) return;                               // after an error: let Node discard the rest
      if ((sent += chunk.length) > opts.maxRequestBytes) {
        return fail(413, { error: `request body over ${opts.maxRequestBytes} bytes` });
      }
      if (!upReq.write(chunk)) req.pause();
    });
    upReq.on('drain', () => req.resume());
    req.on('end', () => { if (!done) upReq.end(); });
  }

  // GET <url><probe> with a short timeout. Any answer below 500 counts as "responds".
  function probe(name, up) {
    const started = Date.now();
    return new Promise((resolve) => {
      const out = { configured: true, path: `/routing/${name}` };
      const r = up.request({
        protocol: up.protocol, hostname: up.hostname, port: up.port,
        method: 'GET', path: up.base + ENGINES[name].probe, headers: { host: up.host },
        timeout: opts.statusTimeoutMs,
      }, (upRes) => {
        const chunks = [];
        let size = 0;
        upRes.on('data', (c) => { if ((size += c.length) <= 64 * 1024) chunks.push(c); });
        upRes.on('end', () => {
          Object.assign(out, { reachable: upRes.statusCode < 500, status: upRes.statusCode, latency_ms: Date.now() - started });
          if (name === 'valhalla') {                // /status: {version, tileset_last_modified, …}
            try {
              const s = JSON.parse(Buffer.concat(chunks).toString());
              if (s.version) out.version = s.version;
              if (s.tileset_last_modified) out.tileset_last_modified = s.tileset_last_modified;
            } catch {}
          }
          resolve(out);
        });
        upRes.on('error', () => resolve({ ...out, reachable: false, error: 'response aborted' }));
      });
      r.on('timeout', () => r.destroy(Object.assign(new Error('timeout'), { code: 'ETIMEDOUT' })));
      r.on('error', (e) => resolve({ ...out, reachable: false, error: e.code || e.message, latency_ms: Date.now() - started }));
      r.end();
    });
  }

  return {
    handles: (pathname) => pathname === '/routing' || pathname.startsWith('/routing/'),

    async handle(req, res, url) {
      if (/^\/routing\/status\/?$/.test(url.pathname)) {
        if (req.method !== 'GET' && req.method !== 'HEAD') return json(res, 405, { error: 'method not allowed' });
        const engines = {};
        await Promise.all(Object.entries(upstreams).map(async ([name, up]) => {
          engines[name] = up ? await probe(name, up) : { configured: false, path: `/routing/${name}` };
        }));
        return json(res, 200, { engines });
      }
      const m = /^\/routing\/(brouter|valhalla)(\/.*)?$/.exec(url.pathname);
      if (!m) return json(res, 404, { error: 'route not found' });
      const [, name, rest = '/'] = m;
      const up = upstreams[name];
      if (!up) {
        return json(res, 503, {
          error: `routing engine "${name}" is not configured on this server`,
          engine: name, hint: `set ${ENGINES[name].env}`,
        });
      }
      forward(name, up, req, res, rest);
    },
  };
}
