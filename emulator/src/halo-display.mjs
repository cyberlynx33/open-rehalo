// The SmartHalo 2's display firmware running on this computer (emulator/display, built from your copy
// of the firmware), as an event emitter: send it the app's commands, taps and motion, and hear what
// it draws on the LEDs and the display, plays on the buzzer and replies.
import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import readline from 'node:readline';
import { BINARY, build } from '../display/build.mjs';

// Builds halo-display if it's missing or older than the simulator's sources.
export function ensureBuilt({ quiet = true } = {}) {
  const here = new URL('../display/', import.meta.url);
  const sources = ['src', 'include'].flatMap((d) =>
    fs.readdirSync(new URL(d, here)).map((f) => new URL(`${d}/${f}`, here)));
  const built = fs.existsSync(BINARY) ? fs.statSync(BINARY).mtimeMs : 0;
  if (!built || sources.some((f) => fs.statSync(f).mtimeMs > built)) build({ quiet });
  return BINARY;
}

const hex = (s) => Uint8Array.from(Buffer.from(s, 'hex'));

// One output line → an event, or null. See the protocol at the top of display/src/main.c.
export function parseLine(line) {
  if (line === 'READY') return { type: 'ready' };
  const kind = line[0];
  const rest = line.slice(2);
  const space = rest.indexOf(' ');
  const t = Number(space < 0 ? rest : rest.slice(0, space));
  const body = space < 0 ? '' : rest.slice(space + 1);
  switch (kind) {
    case 'L': return { type: 'leds', t, leds: hex(body) };
    case 'O': return { type: 'display', t, ram: hex(body) };
    case 'P': {
      const [on, contrast, brightness] = body.split(' ').map(Number);
      return { type: 'panel', t, on: on === 1, contrast, brightness };
    }
    case 'F': return { type: 'front', t, percent: Number(body) };
    case 'N': {
      const [hz, volume, on] = body.split(' ').map(Number);
      return { type: 'buzzer', t, hz, volume, on: on === 1 };
    }
    case 'R': return { type: 'reply', t, bytes: hex(body) };
    case 'U': return { type: 'notify', t, bytes: hex(body) };
    case 'G': return { type: 'log', t, text: body };
    default: return null;
  }
}

const toHex = (bytes) => Buffer.from(bytes).toString('hex');

export class HaloDisplay extends EventEmitter {
  // `batch`: time only passes with wait(); otherwise it follows the wall clock.
  // `fromBoot`: start at power-on with no app connected, instead of booted and connected.
  constructor({ batch = false, fromBoot = false, binary = ensureBuilt() } = {}) {
    super();
    this.batch = batch;
    this.fromBoot = fromBoot;
    const args = [...(batch ? ['--batch'] : []), ...(fromBoot ? ['--from-boot'] : [])];
    this.proc = spawn(binary, args, { stdio: ['pipe', 'pipe', 'inherit'] });
    this.ready = new Promise((resolve) => this.once('ready', resolve));
    this.exited = new Promise((resolve) => this.proc.once('exit', resolve));
    readline.createInterface({ input: this.proc.stdout }).on('line', (line) => {
      const event = parseLine(line);
      if (!event) return;
      this.emit(event.type, event);
      this.emit('event', event);
    });
  }

  write(line) {
    if (this.proc.exitCode === null) this.proc.stdin.write(`${line}\n`);
  }

  // A BLE command as the app sends it: [service, command, payload…].
  send(bytes) { this.write(`C ${toHex(bytes)}`); }
  connect(on = true) { this.write(`K ${on ? 1 : 0}`); }
  // `code`: bit i set = tap i was long.
  tap(code, length) { this.write(`T ${code} ${length}`); }
  swipe(right) { this.write(`S ${right ? 1 : 0}`); }
  motion(moving) { this.write(`M ${moving ? 1 : 0}`); }
  wait(ms) { this.write(`W ${Math.round(ms)}`); }

  close() {
    this.write('Q');
    this.proc.stdin.end();
    return this.exited;
  }
}

// Runs a script in batch mode and resolves with the events after READY. Each step is a call on the
// display, e.g. (d) => d.send([1, 28, …]) or (d) => d.wait(1000).
export async function runScript(steps, options = {}) {
  const display = new HaloDisplay({ ...options, batch: true });
  const events = [];
  let ready = false;
  display.on('event', (e) => {
    if (ready) events.push(e);
    else if (e.type === 'ready') ready = true;
  });
  await display.ready;
  for (const step of steps) step(display);
  await display.close();
  return events;
}
