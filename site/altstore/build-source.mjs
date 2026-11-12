#!/usr/bin/env node
// Builds rehalo's AltStore / SideStore sources from the GitHub Releases of open-rehalo.
//
//   node site/altstore/build-source.mjs --out dist/site/altstore [--repo owner/name] [--base-url URL]
//
// Writes into --out:
//   apps.json      the numbered releases (v* tags)
//   apps-dev.json  the rolling dev-latest build, on top of the same releases
//   icon.png and screenshots/, copied from the repo (see "files" in source.json)
//
// The .ipa files stay in the releases. Each version is read from its own .ipa (version, build,
// minimum iOS, privacy usage descriptions), so the source always says what the download contains:
// AltStore refuses an app whose permissions differ from the ones its source lists.
// A token in GH_TOKEN or GITHUB_TOKEN raises the API's rate limit; public releases don't need one.

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '../..');
const IPA = 'rehalo-unsigned.ipa';
const DEV_TAG = 'dev-latest';

function fail(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

function parseArgs(argv) {
  const opts = {
    repo: process.env.GITHUB_REPOSITORY || 'cyberlynx33/open-rehalo',
    baseURL: 'https://rehalo.app/altstore/',
  };
  const values = { '--out': 'out', '--repo': 'repo', '--base-url': 'baseURL' };
  for (let i = 0; i < argv.length; i++) {
    const key = values[argv[i]];
    if (!key) fail(`unknown argument: ${argv[i]}`);
    if (i + 1 >= argv.length) fail(`${argv[i]} needs a value`);
    opts[key] = argv[++i];
  }
  if (!opts.out) fail('--out is required');
  if (!opts.baseURL.endsWith('/')) opts.baseURL += '/';
  return opts;
}

// ---- .ipa reading: just enough ZIP and plist to get the Info.plist files out --------------------

function zipEntries(buf) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 22 - 0xffff); i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('not a ZIP file');
  const count = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16);
  if (p === 0xffffffff) throw new Error('ZIP64 archives are not supported');
  const entries = new Map();
  for (let n = 0; n < count; n++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) throw new Error('corrupt ZIP central directory');
    const nameLen = buf.readUInt16LE(p + 28);
    entries.set(buf.toString('utf8', p + 46, p + 46 + nameLen), {
      method: buf.readUInt16LE(p + 10),
      compSize: buf.readUInt32LE(p + 20),
      local: buf.readUInt32LE(p + 42),
    });
    p += 46 + nameLen + buf.readUInt16LE(p + 30) + buf.readUInt16LE(p + 32);
  }
  return entries;
}

function zipRead(buf, { method, compSize, local }) {
  const start = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28);
  const data = buf.subarray(start, start + compSize);
  if (method === 0) return Buffer.from(data);
  if (method === 8) return zlib.inflateRawSync(data);
  throw new Error(`unsupported ZIP compression method ${method}`);
}

function parseBinaryPlist(buf) {
  const t = buf.length - 32;
  const offSize = buf[t + 6];
  const refSize = buf[t + 7];
  const numObjects = Number(buf.readBigUInt64BE(t + 8));
  const top = Number(buf.readBigUInt64BE(t + 16));
  const tableAt = Number(buf.readBigUInt64BE(t + 24));
  const uint = (at, size) => { let v = 0; for (let i = 0; i < size; i++) v = v * 256 + buf[at + i]; return v; };
  const offsets = Array.from({ length: numObjects }, (_, i) => uint(tableAt + i * offSize, offSize));
  const lengthAt = (at, info) => {
    if (info !== 0xf) return [info, at + 1];
    const size = 1 << (buf[at + 1] & 0xf);
    return [uint(at + 2, size), at + 2 + size];
  };
  const read = (idx) => {
    const at = offsets[idx];
    const type = buf[at] >> 4;
    const info = buf[at] & 0xf;
    switch (type) {
      case 0x0: return info === 0x9 ? true : info === 0x8 ? false : null;
      case 0x1: return uint(at + 1, 1 << info);
      case 0x2: return info === 2 ? buf.readFloatBE(at + 1) : buf.readDoubleBE(at + 1);
      case 0x5: { const [len, s] = lengthAt(at, info); return buf.toString('latin1', s, s + len); }
      // Copied before swapping: a string shared by two keys is one object, read twice.
      case 0x6: { const [len, s] = lengthAt(at, info); return Buffer.from(buf.subarray(s, s + len * 2)).swap16().toString('utf16le'); }
      case 0xa: { const [len, s] = lengthAt(at, info); return Array.from({ length: len }, (_, i) => read(uint(s + i * refSize, refSize))); }
      case 0xd: {
        const [len, s] = lengthAt(at, info);
        const out = {};
        for (let i = 0; i < len; i++) out[read(uint(s + i * refSize, refSize))] = read(uint(s + (len + i) * refSize, refSize));
        return out;
      }
      default: return null; // dates, data, UIDs: not needed here
    }
  };
  return read(top);
}

function parsePlist(buf) {
  if (buf.toString('latin1', 0, 8) === 'bplist00') return parseBinaryPlist(buf);
  const out = {};
  for (const m of buf.toString('utf8').matchAll(/<key>([^<]+)<\/key>\s*<string>([^<]*)<\/string>/g)) out[m[1]] = m[2];
  return out;
}

// The app's Info.plist, and the usage descriptions of the app and its extensions (the app's win).
function readIpa(buf) {
  const entries = zipEntries(buf);
  const names = [...entries.keys()];
  const appPlist = names.filter((n) => /^Payload\/[^/]+\.app\/Info\.plist$/.test(n));
  if (appPlist.length !== 1) throw new Error(`expected one Payload/*.app/Info.plist, found ${appPlist.length}`);
  const extPlists = names.filter((n) => /^Payload\/[^/]+\.app\/PlugIns\/[^/]+\.appex\/Info\.plist$/.test(n)).sort();
  const info = parsePlist(zipRead(buf, entries.get(appPlist[0])));
  const privacy = {};
  for (const name of [appPlist[0], ...extPlists]) {
    const plist = name === appPlist[0] ? info : parsePlist(zipRead(buf, entries.get(name)));
    for (const [key, value] of Object.entries(plist)) {
      if (key.endsWith('UsageDescription') && typeof value === 'string' && !(key in privacy)) privacy[key] = value;
    }
  }
  return { info, privacy };
}

// ---- release notes: Markdown to the plain text AltStore shows ----------------------------------

function plainText(md) {
  const inline = (s) => s
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/(\*\*|__)(.+?)\1/g, '$2')
    .replace(/`([^`]+)`/g, '$1');
  // Paragraphs and list items are hard-wrapped in the .md files: a wrapped line joins the one before.
  return md.replace(/\r\n/g, '\n').trim().split(/\n\s*\n/).map((block) => {
    const lines = [];
    let joinable = false;
    for (const raw of block.split('\n')) {
      const line = raw.trim();
      const heading = line.match(/^#{1,6}\s+(.*)$/);
      const item = line.match(/^[-*]\s+(.*)$/);
      if (heading) { lines.push(heading[1]); joinable = false; }
      else if (item) { lines.push(`• ${item[1]}`); joinable = true; }
      else if (joinable) lines[lines.length - 1] += ` ${line}`;
      else { lines.push(line); joinable = true; }
    }
    return lines.map(inline).join('\n');
  }).join('\n\n');
}

// ---- GitHub ------------------------------------------------------------------------------------

async function listReleases(repo) {
  const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
  const headers = {
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'rehalo-altstore-source',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  };
  const releases = [];
  for (let page = 1; ; page++) {
    const res = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=100&page=${page}`, { headers });
    if (!res.ok) fail(`GitHub API: ${res.status} ${res.statusText} listing the releases of ${repo}`);
    const batch = await res.json();
    releases.push(...batch);
    if (batch.length < 100) return releases;
  }
}

async function download(url, size) {
  const res = await fetch(url, { headers: { 'User-Agent': 'rehalo-altstore-source' } });
  if (!res.ok) fail(`${res.status} ${res.statusText} downloading ${url}`);
  const buf = Buffer.from(await res.arrayBuffer());
  if (buf.length !== size) fail(`${url} is ${buf.length} bytes, but GitHub lists it as ${size}`);
  return buf;
}

// ---- main --------------------------------------------------------------------------------------

const opts = parseArgs(process.argv.slice(2));
const template = JSON.parse(fs.readFileSync(path.join(HERE, 'source.json'), 'utf8'));
const url = (rel) => new URL(rel, opts.baseURL).href;
const bundleId = template.app.bundleIdentifier;

const releases = (await listReleases(opts.repo)).filter((r) => !r.draft);
const stable = releases.filter((r) => !r.prerelease && r.tag_name.startsWith('v'));
const dev = releases.find((r) => r.tag_name === DEV_TAG);
if (!dev) console.warn(`warning: no ${DEV_TAG} release: the dev source only has the numbered releases`);

// One entry per release: [{ tag, isDev, version, privacy }]
const builds = [];
for (const release of [...stable, ...(dev ? [dev] : [])]) {
  const tag = release.tag_name;
  const asset = release.assets.find((a) => a.name === IPA);
  if (!asset) { console.warn(`warning: ${tag} has no ${IPA}: left out`); continue; }
  const buf = await download(asset.browser_download_url, asset.size);
  let ipa;
  try { ipa = readIpa(buf); } catch (e) { fail(`${tag}/${IPA}: ${e.message}`); }
  const { info, privacy } = ipa;
  const version = info.CFBundleShortVersionString;
  const build = info.CFBundleVersion == null ? '' : String(info.CFBundleVersion);
  if (!version || !build) fail(`${tag}/${IPA} has no CFBundleShortVersionString or CFBundleVersion`);
  if (info.CFBundleIdentifier !== bundleId) fail(`${tag}/${IPA} is ${info.CFBundleIdentifier}, not ${bundleId}`);
  const isDev = tag === DEV_TAG;
  if (!isDev && tag !== `v${version}`) fail(`release ${tag} holds version ${version}`);
  builds.push({
    tag,
    isDev,
    privacy,
    version: {
      version,
      buildVersion: build,
      // dev-latest is one release whose .ipa is replaced: the asset's date is the build's.
      date: isDev ? asset.updated_at : release.published_at,
      localizedDescription: plainText(release.body || `rehalo ${version}`),
      downloadURL: asset.browser_download_url,
      size: asset.size,
      minOSVersion: info.MinimumOSVersion || '17.0',
    },
  });
  console.log(`${tag}: ${version} (${build}), ${asset.size} bytes, iOS ${info.MinimumOSVersion}+, ${Object.keys(privacy).length} usage descriptions`);
}

// Images: copied next to the sources; screenshots carry their size so AltStore lays them out early.
fs.mkdirSync(opts.out, { recursive: true });
for (const [to, from] of Object.entries(template.files)) {
  const target = path.join(opts.out, to);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(path.join(ROOT, from), target);
}
const screenshots = template.app.screenshots.map((rel) => {
  const png = fs.readFileSync(path.join(opts.out, rel));
  if (png.toString('latin1', 1, 4) !== 'PNG') fail(`${rel} is not a PNG`);
  return { imageURL: url(rel), width: png.readUInt32BE(16), height: png.readUInt32BE(20) };
});

for (const meta of Object.values(template.sources)) {
  // AltStore tells versions apart by version and build: a dev-latest that is the same build as a
  // release (one built before the build numbers got a run number) is left out.
  const key = (b) => `${b.version.version} (${b.version.buildVersion})`;
  const released = new Set(builds.filter((b) => !b.isDev).map(key));
  const listed = builds.filter((b) => {
    if (!b.isDev) return true;
    if (!meta.withDevBuild) return false;
    if (released.has(key(b))) { console.warn(`warning: ${meta.file}: ${b.tag} is ${key(b)}, like a release: left out`); return false; }
    return true;
  }).sort((a, b) => Date.parse(b.version.date) - Date.parse(a.version.date));
  if (!listed.length) fail(`${meta.file} would list no version`);
  // AltStore checks the downloaded app against these: list every usage description any version has.
  const privacy = {};
  for (const b of listed) for (const [k, v] of Object.entries(b.privacy)) if (!(k in privacy)) privacy[k] = v;
  const versions = listed.map((b) => b.version);
  const latest = versions[0];
  const { screenshots: _, ...app } = template.app;
  const source = {
    name: meta.name,
    identifier: meta.identifier,
    subtitle: meta.subtitle,
    description: meta.description,
    iconURL: url(template.iconURL),
    website: template.website,
    tintColor: template.tintColor,
    sourceURL: url(meta.file),
    featuredApps: [bundleId],
    apps: [{
      ...app,
      iconURL: url(app.iconURL),
      screenshots,
      versions,
      appPermissions: { entitlements: [], privacy },
      // For clients older than AltStore 2.0, which read the newest version from the app itself.
      version: latest.version,
      versionDate: latest.date,
      versionDescription: latest.localizedDescription,
      downloadURL: latest.downloadURL,
      size: latest.size,
    }],
    news: [],
  };
  fs.writeFileSync(path.join(opts.out, meta.file), JSON.stringify(source, null, 2) + '\n');
  console.log(`${meta.file}: ${versions.map((v) => `${v.version} (${v.buildVersion})`).join(', ')}`);
}
