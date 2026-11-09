// The display firmware running on the computer (emulator/display). Skipped where it can't be built:
// it needs your copy of the SmartHalo 2 firmware and a C compiler (see display/build.mjs).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import vm from 'node:vm';
import { ensureBuilt, parseLine, runScript } from '../src/halo-display.mjs';

let skip = false;
try {
  ensureBuilt();
} catch (e) {
  skip = `halo-display can't be built here: ${e.message.split('\n')[0]}`;
}

const require = createRequire(import.meta.url);
const firmwareJs = require('../../site/firmware.js');
const hex = (bytes) => Buffer.from(bytes).toString('hex');
const of = (events, type) => events.filter((e) => e.type === type);
const replies = (events) => of(events, 'reply').map((e) => e.bytes[0]);
const litPixels = (ram) => ram.reduce((n, b) => n + b.toString(2).replaceAll('0', '').length, 0);

// The display frames of a recording on the website (site/clips.js), decoded as ring.js does.
function recordedDisplayFrames(clipId) {
  const ctx = { window: {} };
  vm.runInNewContext(fs.readFileSync(new URL('../../site/clips.js', import.meta.url), 'utf8'), ctx);
  const b = Buffer.from(ctx.window.HALO_CLIPS[clipId].oled, 'base64');
  const p = { i: 0 };
  const varint = () => {
    let v = 0;
    for (let s = 0; ; s += 7) { const x = b[p.i++]; v += (x & 0x7f) * 2 ** s; if (x < 0x80) return v; }
  };
  const frames = [];
  let ram = new Uint8Array(1024);
  while (p.i < b.length) {
    varint();
    ram = ram.slice();
    let at = 0;
    for (let runs = varint(); runs > 0; runs--) {
      at += varint();
      const n = varint();
      ram.set(b.subarray(p.i, p.i + n), at);
      p.i += n;
      at += n;
    }
    frames.push(hex(ram));
  }
  return frames;
}

test('parses the output protocol', () => {
  assert.deepEqual(parseLine('READY'), { type: 'ready' });
  assert.deepEqual(parseLine('R 12 03'), { type: 'reply', t: 12, bytes: Uint8Array.from([3]) });
  assert.deepEqual(parseLine('P 5 1 127 64'), { type: 'panel', t: 5, on: true, contrast: 127, brightness: 64 });
  assert.deepEqual(parseLine('N 9 2800 100 1'), { type: 'buzzer', t: 9, hz: 2800, volume: 100, on: true });
  assert.deepEqual(parseLine('G 7 Light is locked'), { type: 'log', t: 7, text: 'Light is locked' });
  assert.equal(parseLine('L 10 ' + '00'.repeat(72)).leds.length, 72);
});

test('commands the firmware has no handler for answer UNIMPLEMENTED', { skip }, async () => {
  const events = await runScript([
    (d) => d.send([1, 9, 128, 255, 128, 0, 0, 255, 3, 232, 3, 232, 0, 60, 0, 0]),   // heartbeat
    (d) => d.send([1, 15, 128]),                                                  // setBrightness
    (d) => d.send([1, 11, 128, 255, 128, 0, 90]),                                 // compass
    (d) => d.send([1, 33, 128, 255, 128, 0, 90, 0]),                              // pointer with intro
    (d) => d.wait(100),
  ]);
  assert.deepEqual(replies(events), [3, 3, 3, 3]);
});

test('the clock draws the same display as the recording of the firmware', { skip }, async () => {
  const events = await runScript([
    (d) => d.send([1, 28, 10, 0, 0, 220, 9, 143, 219, 198, 0x13, 0x88, 1, 1, 1, 1]),   // 10:09
    (d) => d.wait(3000),
  ]);
  assert.deepEqual(replies(events), [0]);
  const recorded = recordedDisplayFrames('cards');
  assert.ok(of(events, 'display').some((e) => recorded.includes(hex(e.ram))), 'a display frame matches the recording');
  assert.ok(of(events, 'leds').length > 10, 'the ring animates');
});

test('the battery animation matches site/firmware.js frame by frame', { skip }, async () => {
  const events = await runScript([(d) => d.send([1, 31]), (d) => d.wait(4000)]);
  const sim = of(events, 'leds').map((e) => hex(e.leds));
  const leds = new Uint8Array(512);
  const reference = [];
  for (let clock = 0; clock < 400; clock++) {
    leds.fill(0);
    const done = firmwareJs.battery(leds, clock, 80);   // the simulator's battery is at 80 %
    reference.push(hex(leds.subarray(0, 72)));
    if (done) break;
  }
  assert.ok(sim.length > 10);
  let k = 0;
  for (const frame of sim) {
    while (k < reference.length && reference[k] !== frame) k++;
    assert.ok(k < reference.length, `frame ${frame.slice(0, 24)}… is a firmware.js frame, in order`);
  }
});

test('the speed card draws the number only while the bike moves', { skip }, async () => {
  const run = (moving, kmh) => runScript([
    ...(moving ? [(d) => d.motion(true), (d) => d.wait(4000)] : []),
    (d) => d.send([1, 36, 4, 0xfc, 0x02, 0, 0]),             // go to the speed card
    (d) => d.wait(300),
    (d) => d.send([1, 35, 4, 0xfc, 0x02, 0, 0, 60, kmh, 0]),  // its content, in km/h
    (d) => d.wait(1500),
  ]);
  const shown = (events) => hex(of(events, 'display').at(-1).ram);
  const [parked23, parked24, moving23, moving24] =
    await Promise.all([run(false, 23), run(false, 24), run(true, 23), run(true, 24)]);
  assert.equal(shown(parked23), shown(parked24), 'parked: only the card\'s title, no number');
  assert.notEqual(shown(moving23), shown(moving24), 'moving: the number is drawn');
  assert.ok(litPixels(of(moving23, 'display').at(-1).ram) > 200);
  assert.ok(of(moving23, 'notify').some((e) => e.bytes[0] === 5 && e.bytes[1] === 4), 'the ring asks for the speed card');
});

test('the alarm arms when the app leaves, sounds when the bike moves, and the tap code disarms it', { skip }, async () => {
  const code = 0b01010;   // short, long, short, long, short
  const events = await runScript([
    (d) => d.send([3, 3, 1, 2, 3, 4, code, 5, 1, 1]),
    (d) => d.wait(500),
    (d) => d.connect(false),
    (d) => d.wait(3000),
    (d) => d.motion(true),
    (d) => d.wait(6000),
    (d) => d.motion(false),
    (d) => d.tap(code, 5),
    (d) => d.wait(4000),
  ]);
  const logs = of(events, 'log').map((e) => e.text);
  assert.ok(logs.includes('Light is locked'), 'armed: the front light is locked');
  const sounding = of(events, 'buzzer').filter((e) => e.on);
  assert.ok(sounding.length > 0, 'the buzzer sounds');
  const tapEnd = of(events, 'notify').find((e) => e.bytes[0] === 0)?.t;
  assert.ok(tapEnd, 'the tap code is reported');
  assert.ok(of(events, 'log').some((e) => e.t >= tapEnd && e.text === 'Light is unlocked'), 'disarmed by the code');
});

test('touch onboarding greets in the language set with the date', { skip }, async () => {
  const english = await runScript([(d) => d.send([1, 37]), (d) => d.wait(1000)]);
  const spanish = await runScript([
    (d) => d.send([4, 6, 0, 0, 0, 0, 0, 0, 0, 0, ...Buffer.from('es')]),
    (d) => d.send([1, 37]),
    (d) => d.wait(1000),
  ]);
  const welcome = (events) => of(events, 'display').map((e) => hex(e.ram)).find((h) => litPixels(Buffer.from(h, 'hex')) > 100);
  assert.ok(welcome(english), 'a welcome screen');
  assert.ok(welcome(spanish), 'a welcome screen in Spanish');
  assert.notEqual(welcome(english), welcome(spanish));
});
