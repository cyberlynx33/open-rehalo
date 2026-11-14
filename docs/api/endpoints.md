# SmartHalo 2 — Cloud API (reimplementation)

> Implemented in `sh2-server/`. The API comes from `aolde/smarthalo-api` (definition and stub) and from
> reverse engineering the official app v1.18.0. The authoritative notes are in
> [`official-app-api-notes.md`](official-app-api-notes.md).

The official host was `api.smarthalo.bike`. `sh2-server` keeps the official headers and shapes:
**`x-consumer-token`** is checked on login/signup/refresh and on v2 endpoints when `SH2_CONSUMER_TOKEN`
is set, and isn't required otherwise.

## Endpoints

### Auth (no `x-access-token`)
| Method | Path | Body | Response |
| --- | --- | --- | --- |
| POST | `/auth/local/checkEmail` | `{email}` | raw scalar `true` / `false` |
| POST | `/auth/local/signup` | `{email,password,firstName,lastName,dateOfBirth,language}` | `{access_jwt,refresh_jwt,user}` |
| POST | `/auth/local/login` | `{email,password}` | `{access_jwt,refresh_jwt,user}` |
| POST | `/auth/local/refresh_tokens` | `{data:{refresh_jwt}}` | `{data:[{access_jwt,refresh_jwt}]}` |
| POST | `/auth/forgot` | `{email}` | raw scalar `ok` *(stub)* |

### User (header `x-access-token: <access_jwt>`)
| Method | Path | | |
| --- | --- | --- | --- |
| GET | `/api/v1/users/whoami` | → `SHUser` | |
| PUT | `/api/v1/users/update` | `{user:{...}}` → `ok` | |
| POST | `/api/v1/users/sendConfirm` | → `ok` *(stub)* | |

### Rides (header `x-access-token`)
`GET /api/v1/users/rides` · `POST /api/v1/users/rides/sync` · `GET|PATCH /v2/users/me/rides/:id` ·
`DELETE /api/v2/rides/:id`. Stored per user.

### Configs and favourites (header `x-access-token`)
`GET|PUT|DELETE /api/v2/users/:userId/configs` · `GET|POST|DELETE /api/v2/users/:userId/favourites`.
Stored per user.

### Acknowledged only
`GET /v2/dfu` → `{data:[]}` (no update available) · `POST /api/v2/device_connections` ·
`POST /v2/activities`.

### Routing proxy (optional, not part of the official API)
Forwards to self-hosted routing engines, stripping the prefix: the query string goes through byte for
byte and bodies are streamed both ways. Set up in [`sh2-server/README.md`](../../sh2-server/README.md#routing-engines-optional).
No auth by default; with `SH2_ROUTING_AUTH=true` every `/routing/*` route needs `x-access-token`
(or `Authorization: Bearer`), which is not forwarded.

| Method | Path | Forwarded to | |
| --- | --- | --- | --- |
| any | `/routing/brouter/<path>` | `$SH2_BROUTER_URL/<path>` | BRouter's native HTTP API |
| any | `/routing/valhalla/<path>` | `$SH2_VALHALLA_URL/<path>` | Valhalla's native HTTP API |
| GET | `/routing/status` | — | `{engines:{brouter:{…},valhalla:{…}}}` |

**BRouter**, base `/routing/brouter` (or the engine's own port). A route:

```
GET /routing/brouter/brouter?lonlats=lon,lat|lon,lat[|…]&profile=gravel&alternativeidx=0&format=geojson&timode=3
```

`profile`: `trekking`, `fastbike`, `gravel`, `mtb`, … · `alternativeidx`: 0–3 · `format`: `geojson`,
`gpx`, `kml` · `timode`: turn-instruction style (0 none, 1 auto, 2 locus, 3 osmand, …) · optional
`nogos`, `polylines`, `polygons`, `heading`, `profile:<param>=<value>`. The GeoJSON is a
`FeatureCollection` with one `LineString` of `[lon, lat, elevation]`; its `properties` hold
`track-length`, `filtered ascend`, `total-time`, `voicehints` (`[pointIndex, command, exitNumber,
distanceToNext, angle]` per turn) and `messages` (per-segment way tags). Errors are `400` with a
plain-text message (unknown profile, point not on the map, …). Reference: BRouter's
[`ServerHandler.java`](https://github.com/abrensch/brouter/blob/master/brouter-server/src/main/java/btools/server/request/ServerHandler.java).

**Valhalla**, base `/routing/valhalla`:

- `POST /routing/valhalla/route` with a JSON body, or `GET /routing/valhalla/route?json=<url-encoded JSON>`:
  `{"locations":[{"lat":…,"lon":…},{"lat":…,"lon":…}],"costing":"bicycle",
  "costing_options":{"bicycle":{"bicycle_type":"Hybrid","use_hills":0.5,"use_roads":0.5}},
  "elevation_interval":30,"directions_options":{"language":"es-ES"}}`. `bicycle_type`: `Road`,
  `Hybrid`, `Cross`, `Mountain`. The response `trip.legs[].shape` is an encoded polyline (precision 6),
  `maneuvers[]` the turn-by-turn steps and, with `elevation_interval`, `elevation[]` the heights along
  the leg. Reference: [Valhalla route API](https://valhalla.github.io/valhalla/api/turn-by-turn/api-reference/).
- `GET /routing/valhalla/status` → `{version, tileset_last_modified, available_actions}`. The other
  actions (`height`, `trace_route`, `isochrone`, `locate`, …) pass through the same way.

**Status**: `GET /routing/status` → per engine `{configured, path}` and, when configured, the result of
a probe (`/robots.txt` for BRouter, `/status` for Valhalla): `reachable`, `status`, `latency_ms`, and
Valhalla's `version` and `tileset_last_modified`, or `error`. Engine addresses are not shown.

**Errors** (JSON `{error, engine, …}`): `503` engine not configured (`hint: "set SH2_BROUTER_URL"`) ·
`502` engine unreachable, or response over `SH2_ROUTING_MAX_BYTES` · `504` no answer within
`SH2_ROUTING_TIMEOUT_MS` · `413` request body over 1 MiB · `401` missing or invalid token when auth is on ·
`404` any other `/routing/*` path. The engine's own errors (e.g. BRouter's `400`) pass through unchanged.

## SHUser model (relevant fields)

`email, firstName, lastName, key` (required); `id, dateOfBirth, deviceId, deviceVersion, devicePass,
picture, language, gender, height/weight(+Metric), isConfirmed, created_at`.

> **Key finding**: `devicePass` — the official backend stored **the device's BLE pairing password per
> user**. `sh2-server` stores it through `/api/v1/users/update` and returns it in `whoami`, so a client
> can recover the device password from your own server (see `docs/protocol/pairing.md`).
