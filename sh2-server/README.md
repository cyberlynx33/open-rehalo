# sh2-server

Open-source reimplementation of the SmartHalo 2 cloud backend, for **self-hosting**.
Node ESM, **zero dependencies** (`node:http`, `node:crypto`). Runs in Docker or anywhere with Node.

## Getting started

```bash
npm start                       # listens on :8730
PORT=8730 SH2_DATA_DIR=./data SH2_JWT_SECRET=... npm start
```

Data lives in `SH2_DATA_DIR` (default `./data`): `users.json` + `jwt.secret` (auto-generated).

With Docker: `docker compose up -d` (code mounted read-only on `node:22-alpine`). Settings go in a
`.env` next to `docker-compose.yml`; [`.env.example`](.env.example) lists them all with their defaults.

## Modules

- `jwt.mjs` — JWT HS256 (sign/verify). `auth.mjs` — scrypt password hashing.
- `store.mjs` — `UserStore` in a JSON file (can be migrated to SQLite/Postgres).
- `server.mjs` — `createApp({store,secret,routing})`: router + handlers. `index.mjs` — startup.
- `routing.mjs` — optional streaming proxy to BRouter/Valhalla under `/routing/*` (see below).
- `routing/brouter-segments.mjs` — downloads BRouter's `.rd5` segments (the `brouter-segments` job).

## Endpoints

See [`../docs/api/endpoints.md`](../docs/api/endpoints.md). Auth + User + **complete, persistent
Rides + Favourites + Configs** (shapes aligned with the app's models, see below), plus the optional
**routing proxy** (`/routing/brouter/*`, `/routing/valhalla/*`, `/routing/status`).

## Tests

```
npm test   # node --test: 37 tests over real HTTP (16 API, 16 routing proxy against fake engines,
           # 5 segment downloader against a fake mirror)
```

## Status

- Done: auth (signup/login/refresh/checkEmail) + user (whoami/update); rides v1/v2
  (list/sync/get/patch/delete), favourites (list/create/delete) and configs (get/put/delete),
  real and persistent in `UserStore` (`rides`/`favourites`/`configs` arrays per user).
- Shapes: `SHPastRide` (v1, camelCase), `CloudRide` (v2, snake via `@SerializedName`),
  `RideMarker`/`CloudMarker`/`UserFavourite`.
- Acknowledgement stubs: `v2/dfu` (no update), `device_connections`, `activities`.

## Aligned with the official app v1.18.0
- The **`x-consumer-token`** header is optional. Set `SH2_CONSUMER_TOKEN` to require it on
  login/signup/refresh and on all v2 routes. It has no default; when unset, the header is not required.
- `users/update` = **PUT**; `checkEmail`/`forgot` respond with a **scalar** (`true`/`false`/`ok`);
  `refresh_tokens` uses a `{data:{…}}`→`{data:[{…}]}` envelope.
- v2 endpoints (persistent stubs where applicable): configs, favourites, rides v2, `v2/dfu`,
  `device_connections`, `activities`. Details in `../docs/api/official-app-api-notes.md`.

## Routing engines (optional)

`docker-compose.yml` can also run two open-source bike routers on OpenStreetMap data, each behind a
Compose profile. sh2-server proxies both under `/routing/*`, so the app needs a single server address;
the engines' own ports stay available too. Both speak their **native API**, unchanged.

| Engine | Profile | Direct port | Through sh2-server | Data |
| --- | --- | --- | --- | --- |
| [BRouter](https://github.com/abrensch/brouter) 1.7.10 | `brouter` | `BROUTER_PORT` (17777) | `/routing/brouter/brouter?…` | prebuilt `.rd5` segments, 5°×5° tiles |
| [Valhalla](https://github.com/valhalla/valhalla) 3.9.1 | `valhalla` | `VALHALLA_PORT` (8002) | `/routing/valhalla/route`, `/status`, … | tiles built locally from a Geofabrik PBF |

### Starting them

```bash
cp .env.example .env
# BRouter: downloads the segments for peninsular Spain + Balearics (6 tiles, ~410 MB), then serves
echo 'SH2_BROUTER_URL=http://brouter:17777' >> .env
docker compose --profile brouter up -d
# Valhalla: downloads the Spain PBF and builds tiles, admin/timezone DBs and elevation on the first start
echo 'SH2_VALHALLA_URL=http://valhalla:8002' >> .env
docker compose --profile valhalla up -d

curl -s localhost:8730/routing/status          # which engines are configured and whether they answer
```

- `COMPOSE_PROFILES=brouter,valhalla` in `.env` makes a plain `docker compose up -d` start them as well.
  `docker compose down` stops every service; `docker compose --profile '*' down -v` also deletes the
  downloaded and built data.
- **BRouter image.** The newest official image, `ghcr.io/abrensch/brouter:v1.7.8`, rejects today's
  segments (`lookup version mismatch … lookups.dat=10 W5_N40.rd5=11`): they need 1.7.9 or later, and no
  later release is published as an image. So the first `up` builds the **official Dockerfile at tag
  `v1.7.10`** (`BROUTER_BUILD_CONTEXT`) and tags it `sh2-brouter:1.7.10` (1.5 min here; it needs
  internet for Gradle). Once upstream publishes a newer image, set `BROUTER_IMAGE` to it and run
  `docker compose --profile brouter pull brouter`.
- **BRouter profiles** come with the image: `trekking`, `fastbike`, `gravel`, `mtb`, plus the rest of
  upstream's `misc/profiles2` (`hiking-mountain`, `shortest`, `car-vario`, …). Profiles uploaded through
  `/brouter/profile` live in a 16 MB tmpfs and are gone after a restart.
- **Segments** are only downloaded when missing: the job checks the volume on every start and exits
  in a second when all tiles are there. Choose the area with `BROUTER_BBOX` (every 5° tile it touches)
  or `BROUTER_TILES` (e.g. `W5_N40 E0_N40`); tiles that are open sea don't exist upstream and are skipped.
  Tiles outside the new selection are not deleted.
- **Valhalla** builds from every `*.pbf` in its volume. To switch to another region, start from an
  empty volume (`docker compose --profile valhalla down`, then `docker volume rm sh2-server_valhalla-data`)
  rather than adding a second PBF.
- The engines have no authentication of their own. If only sh2-server should reach them, publish their
  ports on loopback (`BROUTER_PORT=127.0.0.1:17777`, `VALHALLA_PORT=127.0.0.1:8002`).

### Settings

The full list, with comments, is in [`.env.example`](.env.example).

| Variable | Default | Meaning |
| --- | --- | --- |
| `SH2_BROUTER_URL`, `SH2_VALHALLA_URL` | unset | engine base URL as sh2-server sees it; unset = `/routing/<engine>/*` answers 503 |
| `SH2_ROUTING_AUTH` | `false` | `true` = `/routing/*` needs the user's access JWT (`x-access-token`, or `Authorization: Bearer`), like the rest of the API. It is never forwarded to the engine |
| `SH2_ROUTING_TIMEOUT_MS` | `120000` | per proxied request, until the last byte; 504 when the engine doesn't answer in time |
| `SH2_ROUTING_MAX_BYTES` | 16 MiB | per proxied response; a larger one is refused (502) or, when its size isn't announced, cut off. Request bodies are capped at 1 MiB (413) |
| `SH2_PORT`, `BROUTER_PORT`, `VALHALLA_PORT` | `8730`, `17777`, `8002` | host ports; `127.0.0.1:<port>` binds loopback only |
| `BROUTER_BBOX` / `BROUTER_TILES` | `-9.5,35.8,4.5,43.9` / unset | area to download; tiles win over the box |
| `BROUTER_SEGMENTS_UPDATE` | `false` | `true` = on start, re-download the tiles that changed upstream |
| `BROUTER_MAX_THREADS`, `BROUTER_JAVA_OPTS` | `2`, 256 MB heap, SerialGC | parallel routes and JVM options; a route over `-DmaxRunningTime` (110 s) is aborted |
| `VALHALLA_PBF_URL` | Geofabrik Spain | one extract, e.g. `https://download.geofabrik.de/europe/andorra-latest.osm.pbf` |
| `VALHALLA_THREADS` | `2` | build and service threads; fewer = less RAM, slower build |
| `SH2_MEM_LIMIT`, `BROUTER_MEM_LIMIT`, `VALHALLA_MEM_LIMIT` | `256m`, `512m`, `6g` | container memory limits |
| `BROUTER_SEGMENTS_VOLUME`, `VALHALLA_DATA_VOLUME` | named volumes | or a host path, to keep the data on a given disk |

### RAM, disk and time

Measured on a 16-thread x86-64 machine in November 2026, except where marked *estimate*.

| | RAM | Disk | First start |
| --- | --- | --- | --- |
| sh2-server | 21 MiB | — | seconds |
| BRouter, Spain + Balearics | peak 213 MiB with two 400+ km routes at once | 414 MB segments (6 tiles) + 650 MB image | segments: 92 MB in 3 s here, mirror-bound; image build 1.5 min |
| Valhalla, Andorra | build peak 579 MiB (page cache included); serving 64 MiB + page cache | 160 MB, of which 117 MB is the timezone DB | 13 s |
| Valhalla, Spain | *estimate*: a few GB to build (limit `6g`), a few hundred MB plus page cache to serve | *estimate* 8–10 GB: 1.5 GB PBF, tiles twice (directory + tar), ~2 GB of elevation (25 MB per 1° cell), 117 MB timezone DB | *estimate*: an hour or more, longer on a NAS |

- BRouter route times: 72 km `gravel` (Madrid–Cercedilla) in 2–3 s; 435 km `trekking` (Madrid–Bilbao)
  in 12 s with a Madrid–Zaragoza route computed in parallel (9 s). With the JVM defaults (G1, every
  CPU) the same pair peaked at 465 MiB and took 9 s and 7 s: to trade memory for speed, drop
  `-XX:+UseSerialGC -XX:ActiveProcessorCount=2` from `BROUTER_JAVA_OPTS` and set
  `BROUTER_MEM_LIMIT=768m`. Longer routes need more heap (`-Xmx`).
- If the Valhalla build is killed for memory (`docker inspect -f '{{.State.OOMKilled}}' <container>`),
  raise `VALHALLA_MEM_LIMIT` or lower `VALHALLA_THREADS`. Its healthcheck allows 3 h for the first build.

### Updating the data

OSM changes every day; refreshing monthly is plenty for routing.

**BRouter** — the job re-downloads only the tiles whose `Last-Modified` changed (conditional requests),
and a failed update keeps the old tile:

```bash
BROUTER_SEGMENTS_UPDATE=true docker compose --profile brouter run --rm brouter-segments
docker compose --profile brouter restart brouter
```

Or set `BROUTER_SEGMENTS_UPDATE=true` in `.env` so that every `up` checks. A monthly cron line:
`0 4 1 * * cd /path/to/sh2-server && BROUTER_SEGMENTS_UPDATE=true docker compose --profile brouter run --rm brouter-segments && docker compose --profile brouter restart brouter`.

**Valhalla** — fetch the PBF again (only if it changed), rebuild once, serve. Routing is down during
the rebuild; the admin, timezone and elevation data are reused. The file name is the last part of
`VALHALLA_PBF_URL`:

```bash
docker compose --profile valhalla stop valhalla
docker compose --profile valhalla run --rm --no-deps --entrypoint curl valhalla -fL -R \
  -z /custom_files/spain-latest.osm.pbf -o /custom_files/spain-latest.osm.pbf \
  https://download.geofabrik.de/europe/spain-latest.osm.pbf
docker compose --profile valhalla run --rm --no-deps -e force_rebuild=True -e serve_tiles=False valhalla
docker compose --profile valhalla up -d valhalla
```

### Using it from the app

- **BRouter base URL**, through sh2-server: `https://server.example.org/routing/brouter`; directly:
  `http://server.example.org:17777`. The app appends BRouter's own path and query, and both accept
  exactly the same request:
  `<base>/brouter?lonlats=lon,lat|lon,lat&profile=gravel&alternativeidx=0&format=geojson&timode=3`.
  The GeoJSON carries the turn hints in `properties.voicehints` and `[lon, lat, elevation]` coordinates.
- **Valhalla base URL**: `https://server.example.org/routing/valhalla` (append `/route`, `/status`, …)
  or `http://server.example.org:8002`.
- With `SH2_ROUTING_AUTH=true` the client must send the access token in `x-access-token`, as for rides.
- The app allows plain HTTP only to IP addresses, names without a dot and `.local`, `.lan`, `.home`,
  `.internal` and `.home.arpa` hosts. Any other host needs HTTPS (a TLS reverse proxy in front of
  sh2-server).
- Routes come from OpenStreetMap data: show "© OpenStreetMap contributors" where they are displayed
  (see `../NOTICE.md`).
