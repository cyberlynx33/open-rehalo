import { randomBytes } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { createApp, UserStore } from './server.mjs';

const PORT = Number(process.env.PORT || 8730);
const DATA_DIR = process.env.SH2_DATA_DIR || new URL('../data', import.meta.url).pathname;
mkdirSync(DATA_DIR, { recursive: true });

// persisted JWT secret (or from env)
let secret = process.env.SH2_JWT_SECRET;
if (!secret) {
  const sp = `${DATA_DIR}/jwt.secret`;
  if (existsSync(sp)) secret = readFileSync(sp, 'utf8').trim();
  else { secret = randomBytes(32).toString('hex'); writeFileSync(sp, secret); }
}

// optional routing proxy (/routing/*); an unset engine URL answers 503, empty numbers keep the defaults
const envNum = (k) => (process.env[k] ? Number(process.env[k]) : undefined);
const routing = {
  brouterUrl: process.env.SH2_BROUTER_URL || undefined,
  valhallaUrl: process.env.SH2_VALHALLA_URL || undefined,
  auth: /^(1|true|yes|on)$/i.test(process.env.SH2_ROUTING_AUTH || ''),   // off by default
  timeoutMs: envNum('SH2_ROUTING_TIMEOUT_MS'),
  maxResponseBytes: envNum('SH2_ROUTING_MAX_BYTES'),
};

const store = new UserStore(`${DATA_DIR}/users.json`);
const app = createApp({
  store, secret,
  consumerToken: process.env.SH2_CONSUMER_TOKEN || undefined, // optional; unset = header not required
  routing,
});
app.listen(PORT, () => {
  console.log(`sh2-server listening on http://0.0.0.0:${PORT}`);
  const on = ['brouter', 'valhalla'].filter((e) => routing[`${e}Url`]);
  console.log(`routing proxy: ${on.length ? on.join(', ') : 'no engine configured'}${routing.auth ? ' (JWT required)' : ''}`);
});
