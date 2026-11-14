// SmartHalo 2 — cloud server (open-source reimplementation). node:http, no dependencies.
// Shapes/routes aligned with the official app v1.18.0 (see docs/api/official-app-api-notes.md):
//   - optional x-consumer-token header on login/signup/refresh and all v2 routes (needs SH2_CONSUMER_TOKEN)
//   - x-access-token (access_jwt) on authenticated endpoints
//   - users/update is PUT; checkEmail/forgot return a raw scalar; refresh uses a {data:…} envelope
// Plus an optional proxy to self-hosted routing engines under /routing/* (see routing.mjs).
import { createServer } from 'node:http';
import { sign, verify } from './jwt.mjs';
import { hashPassword, verifyPassword } from './auth.mjs';
import { UserStore, publicUser } from './store.mjs';
import { createRouting } from './routing.mjs';

const ACCESS_TTL = 3600;               // 1 h
const REFRESH_TTL = 60 * 60 * 24 * 30; // 30 d

function json(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}
function text(res, status, body) {               // scalar responses (ScalarsConverter)
  res.writeHead(status, { 'content-type': 'text/plain; charset=utf-8' });
  res.end(String(body));
}
function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      const raw = Buffer.concat(chunks).toString();
      try { resolve(JSON.parse(raw)); }
      catch { resolve({ _raw: raw }); }           // form-urlencoded / text: don't fail
    });
  });
}
function tokensFor(user, secret) {
  return {
    access_jwt: sign({ sub: user.id, email: user.email, typ: 'access' }, secret, { expiresInSec: ACCESS_TTL }),
    refresh_jwt: sign({ sub: user.id, typ: 'refresh' }, secret, { expiresInSec: REFRESH_TTL }),
  };
}

// ---- Ride shapes aligned with the official app (default GsonBuilder(): v1 camelCase, v2 snake) ----
// Official app models: SHPastRide, CloudRide, CloudMarker, CloudSignificantMarker, RideMarker, RideUploadPayload, RideUploadLocation
const num = (v, d = 0) => (v == null || Number.isNaN(Number(v)) ? d : Number(v));

// Builds the canonical internal ride from a RideUploadPayload.
function rideFromUpload(p, userId, now) {
  const markers = (Array.isArray(p?.markers) ? p.markers : []).map((loc) => {
    const c = loc?.coords ?? {};                   // RideUploadLocation = { coords: SHLocation, timestamp }
    return {
      accuracy: num(c.accuracy), altitude: num(c.altitude), heading: num(c.heading),
      latitude: num(c.latitude), longitude: num(c.longitude), speed: num(c.speed),
      timestamp: num(loc?.timestamp),
    };
  });
  const sig = markers.length
    ? [{ latitude: markers[0].latitude, longitude: markers[0].longitude },
       { latitude: markers.at(-1).latitude, longitude: markers.at(-1).longitude }]
    : [];
  return {
    user_id: userId,
    stamp: p?.stamp != null ? String(p.stamp) : String(Date.now()),
    start: p?.start ?? null, end: p?.end ?? null,
    createdAt: now, updatedAt: now,
    duration: num(p?.duration), distance: num(p?.distance),
    averageSpeed: num(p?.averageSpeed), maxSpeed: num(p?.maxSpeed),
    elevation: num(p?.elevation), calories: num(p?.calories), co2: num(p?.co2),
    type: null, fitnessIntegrations: p?.integration ?? null,
    markers, significantMarkers: sig,
  };
}

// GET /api/v1/users/rides -> [SHPastRide] (no @SerializedName except integration => camelCase keys)
function asPastRide(r) {
  return {
    id: r.id, stamp: r.stamp, start: r.start, end: r.end,
    createdAt: r.createdAt, updatedAt: r.updatedAt,
    duration: r.duration, distance: r.distance, averageSpeed: r.averageSpeed,
    elevation: r.elevation, calories: r.calories, co2: r.co2,
    user_id: r.user_id, integration: r.fitnessIntegrations ?? null,
  };
}

// {data:[CloudRide]} (@SerializedName => average_speed/created_at/updated_at/significant_markers/integration)
function asCloudRide(r) {
  return {
    id: r.id, stamp: r.stamp, start: r.start, end: r.end, type: r.type ?? null,
    created_at: r.createdAt, updated_at: r.updatedAt,
    average_speed: r.averageSpeed, calories: r.calories, co2: r.co2,
    distance: r.distance, duration: r.duration, elevation: r.elevation,
    integration: r.fitnessIntegrations ?? null,
    markers: (r.markers ?? []).map((m) => ({            // CloudMarker (flat fields, no @SerializedName)
      accuracy: m.accuracy, altitude: m.altitude, heading: m.heading,
      latitude: m.latitude, longitude: m.longitude, speed: m.speed, timestamp: m.timestamp,
    })),
    significant_markers: r.significantMarkers ?? [],     // CloudSignificantMarker = {latitude, longitude}
  };
}

// POST /api/v1/users/rides/sync -> [[RideMarker]] (@SerializedName: ride_id/created_at/updated_at)
function rideMarker(m, rideId, now) {
  return {
    id: num(m?.id ?? m?.timestamp), ride_id: rideId,
    latitude: num(m?.latitude), longitude: num(m?.longitude), altitude: num(m?.altitude),
    speed: num(m?.speed), heading: num(m?.heading), accuracy: num(m?.accuracy),
    activityType: null, activityConfidence: null,
    timestamp: num(m?.timestamp), created_at: now, updated_at: now,
  };
}

// `routing`: { brouterUrl, valhallaUrl, auth, timeoutMs, maxResponseBytes } (all optional, see routing.mjs)
export function createApp({ store, secret, consumerToken, requireConsumer = Boolean(consumerToken), routing = {} } = {}) {
  const { auth: routingAuth = false, ...routingOpts } = routing;
  const proxy = createRouting(routingOpts);
  const routes = [];
  const add = (method, pattern, handler, opts = {}) => {
    const keys = [];
    const re = new RegExp('^' + pattern.replace(/:(\w+)/g, (_, k) => { keys.push(k); return '([^/]+)'; }) + '/?$');
    routes.push({ method, re, keys, handler, auth: !!opts.auth, consumer: !!opts.consumer });
  };

  // ---- Auth ----
  add('POST', '/auth/local/checkEmail', async (req, res, { body }) => {
    if (!body?.email) return text(res, 400, 'email required');
    text(res, 200, store.findByEmail(body.email) ? 'true' : 'false');   // raw scalar
  });
  add('POST', '/auth/forgot', async (req, res) => text(res, 200, 'ok')); // scalar; stub
  add('POST', '/auth/local/signup', async (req, res, { body }) => {
    if (!body?.email || !body?.password) return json(res, 400, { error: 'email and password required' });
    if (store.findByEmail(body.email)) return json(res, 409, { error: 'email already registered' });
    const user = store.create({
      email: body.email, firstName: body.firstName ?? '', lastName: body.lastName ?? '',
      dateOfBirth: body.dateOfBirth, language: body.language ?? 'en',
      passwordHash: hashPassword(body.password),
    });
    json(res, 200, { ...tokensFor(user, secret), user: publicUser(user) });
  }, { consumer: true });
  add('POST', '/auth/local/login', async (req, res, { body }) => {
    const user = body?.email ? store.findByEmail(body.email) : null;
    if (!user || !verifyPassword(body.password, user.passwordHash)) {
      return json(res, 401, { error: 'invalid credentials' });
    }
    json(res, 200, { ...tokensFor(user, secret), user: publicUser(user) });
  }, { consumer: true });
  add('POST', '/auth/local/refresh_tokens', async (req, res, { body }) => {
    const refresh = body?.data?.refresh_jwt ?? body?.refresh_jwt;   // {data:{…}} envelope
    const claims = verify(refresh, secret);
    if (!claims || claims.typ !== 'refresh') return json(res, 401, { error: 'invalid refresh token' });
    const user = store.findById(claims.sub);
    if (!user) return json(res, 401, { error: 'user does not exist' });
    json(res, 200, { data: [tokensFor(user, secret)] });            // response is an array inside data
  }, { consumer: true });

  // ---- User (x-access-token) ----
  add('GET', '/api/v1/users/whoami', async (req, res, { user }) => json(res, 200, publicUser(user)), { auth: true });
  add('POST', '/api/v1/users/sendConfirm', async (req, res) => text(res, 200, 'ok'), { auth: true });
  add('PUT', '/api/v1/users/update', async (req, res, { user, body }) => {   // PUT, not POST
    const patch = { ...(body?.user ?? body ?? {}) };
    delete patch.id; delete patch.passwordHash; delete patch.key;
    if (patch.password) { patch.passwordHash = hashPassword(patch.password); delete patch.password; }
    store.update(user.id, patch);
    text(res, 200, 'ok');                                            // the app expects a String
  }, { auth: true });

  // ---- Device configs (v2; auth + consumer) ----
  add('GET', '/api/v2/users/:userId/configs', async (req, res, { user }) =>
    json(res, 200, { success: true, configs: user.configs ?? {} }), { auth: true, consumer: true });
  add('PUT', '/api/v2/users/:userId/configs', async (req, res, { user, body }) => {
    const merged = { ...(user.configs ?? {}), ...(body?.configs ?? {}) };
    store.update(user.id, { configs: merged });
    json(res, 200, { success: true });
  }, { auth: true, consumer: true });
  add('DELETE', '/api/v2/users/:userId/configs', async (req, res, { user, body }) => {
    const cfg = { ...(user.configs ?? {}) };
    for (const k of Object.keys(body?.configs ?? {})) delete cfg[k];
    store.update(user.id, { configs: cfg });
    json(res, 200, true);
  }, { auth: true, consumer: true });

  // ---- Favourites (v2; auth + consumer) ----
  // GET -> [UserFavourite]; keys: id(PK), user_id, favourite_type, address, label, lat, lng, createdAt, updatedAt
  add('GET', '/api/v2/users/:userId/favourites', async (req, res, { user }) =>
    json(res, 200, user.favourites ?? []), { auth: true, consumer: true });
  // POST body SHCreateFavouriteRequest {user_id, favourite_type, address, label, lat, lng} -> Boolean
  add('POST', '/api/v2/users/:userId/favourites', async (req, res, { user, body, params }) => {
    const fav = user.favourites ?? [];
    const id = fav.reduce((mx, f) => Math.max(mx, Number(f.id) || 0), 0) + 1;
    const now = new Date().toISOString();
    fav.push({
      id,                                                 // UserFavourite.id (PrimaryKey Integer)
      user_id: Number(body?.user_id ?? params.userId ?? user.id),
      favourite_type: body?.favourite_type ?? 'FAVOURITE',  // FAVOURITE | HOME | WORK
      address: body?.address ?? null,
      label: body?.label ?? null,
      lat: num(body?.lat), lng: num(body?.lng),             // @SerializedName lat/lng
      createdAt: now, updatedAt: now,
    });
    store.update(user.id, { favourites: fav });
    json(res, 200, true);                                   // Call<Boolean>
  }, { auth: true, consumer: true });
  // DELETE form-urlencoded favourite_id -> Boolean (deletes by UserFavourite.id)
  add('DELETE', '/api/v2/users/:userId/favourites', async (req, res, { user, body }) => {
    const raw = body?._raw || '';
    const id = Number(body?.favourite_id ?? body?.id ?? new URLSearchParams(raw).get('favourite_id'));
    const fav = (user.favourites ?? []).filter((f) => Number(f.id) !== id);
    store.update(user.id, { favourites: fav });
    json(res, 200, true);
  }, { auth: true, consumer: true });

  // ---- Rides (persistent per user) ----
  // GET -> [SHPastRide]
  add('GET', '/api/v1/users/rides', async (req, res, { user }) =>
    json(res, 200, store.listRides(user.id).map(asPastRide)), { auth: true });
  // POST body [RideUploadPayload] -> [[RideMarker]] (the app reads body[0][0].ride_id)
  add('POST', '/api/v1/users/rides/sync', async (req, res, { user, body }) => {
    const payloads = Array.isArray(body) ? body : (Array.isArray(body?.data) ? body.data : []);
    const now = new Date().toISOString();
    const out = [];
    for (const p of payloads) {
      const stamp = p?.stamp != null ? String(p.stamp) : null;
      const existing = stamp ? store.listRides(user.id).find((r) => r.stamp === stamp) : null;
      const data = rideFromUpload(p, user.id, now);
      const ride = existing
        ? store.updateRide(user.id, existing.id, { ...data, createdAt: existing.createdAt })  // dedup by stamp (PK)
        : store.createRide(user.id, data);
      const markers = ride.markers.length
        ? ride.markers.map((m) => rideMarker(m, ride.id, now))
        : [rideMarker({}, ride.id, now)];        // makes sure ride_id is sent even with no markers
      out.push(markers);
    }
    json(res, 200, out);
  }, { auth: true });
  // GET /v2/users/me/rides/{id} -> {data:[CloudRide]}
  add('GET', '/v2/users/me/rides/:ride_id', async (req, res, { user, params }) => {
    const ride = store.getRide(user.id, params.ride_id);
    json(res, 200, { data: ride ? [asCloudRide(ride)] : [] });
  }, { auth: true, consumer: true });
  // PATCH body {data:PatchRideRequest} -> {data:[CloudRide]}
  add('PATCH', '/v2/users/me/rides/:ride_id', async (req, res, { user, params, body }) => {
    const ride = store.getRide(user.id, params.ride_id);
    if (!ride) return json(res, 200, { data: [] });
    const p = body?.data ?? body ?? {};
    const patch = { updatedAt: new Date().toISOString() };
    if (p.start !== undefined) patch.start = p.start;
    if (p.end !== undefined) patch.end = p.end;
    if (p.distance !== undefined) patch.distance = num(p.distance);
    if (p.average_speed !== undefined) patch.averageSpeed = num(p.average_speed);
    if (p.duration !== undefined) patch.duration = num(p.duration);
    if (p.elevation !== undefined) patch.elevation = num(p.elevation);
    if (p.calories !== undefined) patch.calories = num(p.calories);
    if (p.co2 !== undefined) patch.co2 = num(p.co2);
    if (p.integration !== undefined) patch.fitnessIntegrations = p.integration;
    json(res, 200, { data: [asCloudRide(store.updateRide(user.id, ride.id, patch))] });
  }, { auth: true, consumer: true });
  // DELETE /api/v2/rides/{id} -> Boolean
  add('DELETE', '/api/v2/rides/:ride_id', async (req, res, { user, params }) => {
    store.deleteRide(user.id, params.ride_id);
    json(res, 200, true);
  }, { auth: true, consumer: true });

  // ---- Firmware OTA (v2; auth + consumer) ----
  add('GET', '/v2/dfu', async (req, res) => json(res, 200, { data: [] }), { auth: true, consumer: true }); // no update

  // ---- Device connections / activities (v2) ----
  add('POST', '/api/v2/device_connections', async (req, res) => json(res, 200, { success: true }), { auth: true, consumer: true });
  add('POST', '/v2/activities', async (req, res, { body }) => json(res, 200, { data: [body?.data ?? {}] }), { auth: true, consumer: true });

  // health
  add('GET', '/health', async (req, res) => json(res, 200, { ok: true }));

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x');

    // routing proxy: streams its own bodies, so it runs before readBody(); JWT only when SH2_ROUTING_AUTH is on
    if (proxy.handles(url.pathname)) {
      if (routingAuth) {
        const bearer = /^Bearer\s+(\S+)$/i.exec(req.headers.authorization ?? '')?.[1];
        const claims = verify(req.headers['x-access-token'] ?? bearer, secret);
        if (!claims || claims.typ !== 'access' || !store.findById(claims.sub)) {
          return json(res, 401, { error: 'invalid token' });
        }
      }
      try { return await proxy.handle(req, res, url); }
      catch (e) { return res.headersSent ? res.destroy() : json(res, 500, { error: String(e?.message || e) }); }
    }

    const route = routes.find((r) => r.method === req.method && r.re.test(url.pathname));
    if (!route) return json(res, 404, { error: 'route not found' });

    const params = {};
    const m = url.pathname.match(route.re);
    route.keys.forEach((k, i) => { params[k] = decodeURIComponent(m[i + 1]); });

    const body = ['POST', 'PATCH', 'PUT', 'DELETE'].includes(req.method) ? await readBody(req) : {};

    // consumer header (only enforced when a consumer token is configured)
    if (route.consumer && requireConsumer && req.headers['x-consumer-token'] !== consumerToken) {
      return json(res, 401, { error: 'invalid or missing x-consumer-token' });
    }

    let user = null;
    if (route.auth) {
      const claims = verify(req.headers['x-access-token'], secret);
      if (!claims || claims.typ !== 'access') return json(res, 401, { error: 'invalid token' });
      user = store.findById(claims.sub);
      if (!user) return json(res, 401, { error: 'user does not exist' });
    }
    try { await route.handler(req, res, { body, params, user }); }
    catch (e) { json(res, 500, { error: String(e?.message || e) }); }
  });
  return server;
}

export { UserStore };
