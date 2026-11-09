// The emulator's preview: the SmartHalo 2's own display firmware (emulator/display) running live on
// this computer, drawn in the browser the way the website draws its recordings (halo-view.js). It
// only runs locally; it isn't part of the website.
//
//   node emulator/preview/server.mjs        then open http://127.0.0.1:8090
//
// PORT changes the port. The firmware comes from your copy (see emulator/display/build.mjs).
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { HaloDisplay, ensureBuilt } from '../src/halo-display.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.PORT || 8090);

// The page is only these files, all in emulator/preview.
const FILES = {
  '/': [path.join(here, 'index.html'), 'text/html; charset=utf-8'],
  '/preview.css': [path.join(here, 'preview.css'), 'text/css; charset=utf-8'],
  '/preview.js': [path.join(here, 'preview.js'), 'text/javascript; charset=utf-8'],
  '/app-commands.js': [path.join(here, 'app-commands.js'), 'text/javascript; charset=utf-8'],
  '/halo-view.js': [path.join(here, 'halo-view.js'), 'text/javascript; charset=utf-8'],
};

const hex = (bytes) => Buffer.from(bytes).toString('hex');

// What a page that opens now must be shown first: the last of each.
let latest = {};
let display;
const clients = new Set();

function broadcast(event) {
  const data = `data: ${JSON.stringify(event)}\n\n`;
  for (const res of clients) res.write(data);
}

function toWire(e) {
  switch (e.type) {
    case 'leds': return { type: e.type, t: e.t, leds: hex(e.leds) };
    case 'display': return { type: e.type, t: e.t, ram: hex(e.ram) };
    case 'reply': case 'notify': return { type: e.type, t: e.t, bytes: hex(e.bytes) };
    default: return e;
  }
}

function start(fromBoot = false) {
  latest = {};
  display = new HaloDisplay({ fromBoot });
  display.on('event', (e) => {
    const wire = toWire(e);
    if (['leds', 'display', 'panel', 'front', 'buzzer'].includes(e.type)) latest[e.type] = wire;
    broadcast(wire);
  });
  display.proc.once('exit', (code, signal) => {
    if (display.restarting) return;
    broadcast({ type: 'log', t: 0, text: `the firmware stopped (${signal || code}); restart it to go on` });
  });
}

async function restart(fromBoot) {
  display.restarting = true;
  await display.close();
  start(fromBoot);
  broadcast({ type: 'restart', fromBoot });
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 1e5) req.destroy(); });
    req.on('end', () => { try { resolve(JSON.parse(body || '{}')); } catch (e) { reject(e); } });
  });
}

async function input(msg) {
  switch (msg.type) {
    case 'command': {
      const bytes = Buffer.from(String(msg.hex).replace(/[^0-9a-f]/gi, ''), 'hex');
      if (bytes.length < 2) throw new Error('a command needs at least [service, command]');
      display.send(bytes);
      broadcast({ type: 'sent', bytes: hex(bytes), label: msg.label || '' });
      break;
    }
    case 'tap': display.tap(Number(msg.code) | 0, Number(msg.length) | 0); break;
    case 'swipe': display.swipe(!!msg.right); break;
    case 'motion': display.motion(!!msg.on); break;
    case 'connect': display.connect(!!msg.on); break;
    case 'restart': await restart(!!msg.fromBoot); break;
    default: throw new Error(`unknown input ${msg.type}`);
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (req.method === 'GET' && url.pathname === '/events') {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
    res.write(`data: ${JSON.stringify({ type: 'hello' })}\n\n`);
    for (const e of Object.values(latest)) res.write(`data: ${JSON.stringify(e)}\n\n`);
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  if (req.method === 'POST' && url.pathname === '/input') {
    try {
      await input(await readJson(req));
      res.writeHead(204).end();
    } catch (e) {
      res.writeHead(400, { 'content-type': 'text/plain' }).end(e.message);
    }
    return;
  }
  const file = req.method === 'GET' && FILES[url.pathname];
  if (!file) return res.writeHead(404).end();
  res.writeHead(200, { 'content-type': file[1], 'cache-control': 'no-store' });
  fs.createReadStream(file[0]).pipe(res);
});

try {
  ensureBuilt({ quiet: false });
} catch (e) {
  console.error(e.message);
  process.exit(1);
}
start();
server.listen(port, '127.0.0.1', () => console.log(`Halo preview: http://127.0.0.1:${port}`));
