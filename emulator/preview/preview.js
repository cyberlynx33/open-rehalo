// The preview page: the firmware's frames arrive live from server.mjs (/events) and are drawn with
// halo-view.js (the website ring's drawing); buttons send the bytes the app sends (app-commands.js).
import * as C from './app-commands.js';

const $ = (id) => document.getElementById(id);
const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join(' ');
const fromHex = (s) => Uint8Array.from(s.match(/../g) || [], (h) => parseInt(h, 16));

// ---- the ring --------------------------------------------------------------------------------

const view = new window.HaloView($('ring'));
const state = { leds: null, ram: null, panelOn: false, front: 0, t: 0, dirty: true };
view.observeSize(() => { state.dirty = true; });

(function draw() {
  if (state.dirty) {
    view.paint(state.leds, state.panelOn ? state.ram : null, state.front);
    state.dirty = false;
  }
  requestAnimationFrame(draw);
})();

// ---- talking to the server -------------------------------------------------------------------

async function post(msg) {
  const res = await fetch('/input', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(msg) });
  if (!res.ok) log('fw', '!', await res.text());
}

const send = (label, bytes) => post({ type: 'command', hex: hex(bytes), label });

// ---- the log ---------------------------------------------------------------------------------

const RETURN = ['OK', 'FAIL', 'DENIED', 'UNIMPLEMENTED', 'UNNECESSARY'];
const CARDS = ['navigation', 'goal', 'distance', 'time', 'speed', 'calories', 'clock', 'average speed', 'CO2', 'battery'];

function log(kind, mark, text, t = state.t) {
  const li = document.createElement('li');
  li.className = kind;
  li.innerHTML = '<span class="t"></span><span class="m"></span><span class="x"></span>';
  li.querySelector('.t').textContent = `${(t / 1000).toFixed(2)} s`;
  li.querySelector('.m').textContent = mark;
  li.querySelector('.x').textContent = text;
  const list = $('log');
  const atBottom = list.scrollTop + list.clientHeight >= list.scrollHeight - 4;
  list.append(li);
  while (list.children.length > 400) list.firstChild.remove();
  if (atBottom) list.scrollTop = list.scrollHeight;
}
$('clear').addEventListener('click', () => { $('log').textContent = ''; });

function describeNotify(b) {
  if (b[0] === 0) return `touch: ${[...Array(b[2])].map((_, i) => ((b[1] >> i) & 1 ? 'long' : 'short')).join(', ')}`;
  if (b[0] === 2) return `movement: ${b[1] ? 'moving' : 'still'}`;
  if (b[0] === 3) return `front light: ${b[2] ? 'on' : 'off'}`;
  if (b[0] === 5) return `the ring shows the ${CARDS[b[1]] || b[1]} card and asks for its content`;
  return hex([...b]);
}

// ---- events from the firmware ----------------------------------------------------------------

const status = $('status');
const events = new EventSource('/events');
events.onopen = () => { status.textContent = 'live'; status.className = 'status live'; };
events.onerror = () => { status.textContent = 'server unreachable'; status.className = 'status down'; };
events.onmessage = (m) => {
  const e = JSON.parse(m.data);
  if (typeof e.t === 'number') {
    state.t = e.t;
    $('tick').textContent = `${(e.t / 1000).toFixed(1)} s`;
  }
  switch (e.type) {
    case 'leds': state.leds = fromHex(e.leds); state.dirty = true; break;
    case 'display': state.ram = fromHex(e.ram); state.dirty = true; break;
    case 'panel':
      state.panelOn = e.on;
      state.dirty = true;
      $('panel').textContent = e.on ? `on · contrast ${e.contrast}` : 'off';
      break;
    case 'front': state.front = e.percent; state.dirty = true; $('front').textContent = `${e.percent} %`; break;
    case 'buzzer': buzzer(e); break;
    case 'sent': log('sent', '→', `${e.bytes}${e.label ? `  ${e.label}` : ''}`); break;
    case 'reply': {
      const b = fromHex(e.bytes);
      log(`reply${b[0] ? ' bad' : ''}`, '←', `${RETURN[b[0]] ?? b[0]}${b.length > 1 ? ` ${hex([...b.slice(1)])}` : ''}`, e.t);
      break;
    }
    case 'notify': {
      const b = fromHex(e.bytes);
      log('notify', '↑', describeNotify(b), e.t);
      if (b[0] === 5) answerCard(b[1]);
      break;
    }
    case 'log': log('fw', '·', e.text, e.t); break;
    case 'restart':
      Object.assign(state, { leds: null, ram: null, panelOn: false, front: 0, t: 0, dirty: true });
      $('connected').checked = !e.fromBoot;
      $('moving').checked = false;
      log('fw', '·', e.fromBoot ? 'firmware restarted at power-on, no app connected' : 'firmware restarted, booted and connected');
      break;
  }
};

// ---- acting as the app: the ring's cards ------------------------------------------------------

const ride = { kmh: 23, metres: 0, started: performance.now(), last: performance.now() };
setInterval(() => {
  const now = performance.now();
  if ($('moving').checked) ride.metres += (ride.kmh / 3.6) * ((now - ride.last) / 1000);
  ride.last = now;
}, 500);

function answerCard(card) {
  if (!$('answer').checked) return;
  const mask = C.DEFAULT_CARDS;
  const d = new Date();
  const seconds = Math.round((performance.now() - ride.started) / 1000);
  const answers = {
    [C.CarouselCard.navigation]: () => C.carouselNavigationCard(mask),
    [C.CarouselCard.distance]: () => C.carouselDistance(mask, Math.round(ride.metres)),
    [C.CarouselCard.time]: () => C.carouselTime(mask, seconds),
    [C.CarouselCard.speed]: () => C.carouselSpeed(mask, ride.kmh),
    [C.CarouselCard.clock]: () => C.carouselClock(mask, d.getHours(), d.getMinutes()),
    [C.CarouselCard.avgSpeed]: () => C.carouselAvgSpeed(mask, 21, ride.kmh),
    [C.CarouselCard.battery]: () => C.carouselBattery(mask),
  };
  if (answers[card]) send(`${CARDS[card]} card`, answers[card]());
}

// ---- the buzzer ------------------------------------------------------------------------------

let audio, osc, gain;
function buzzer(e) {
  $('buzzer').textContent = e.on ? `${e.hz} Hz · ${e.volume}` : 'silent';
  if (!$('sound').checked) return;
  if (!audio) {
    audio = new AudioContext();
    osc = audio.createOscillator();
    gain = audio.createGain();
    osc.type = 'square';
    gain.gain.value = 0;
    osc.connect(gain).connect(audio.destination);
    osc.start();
  }
  const at = audio.currentTime;
  if (e.on && e.hz > 0) osc.frequency.setValueAtTime(e.hz, at);
  gain.gain.setTargetAtTime(e.on && e.hz > 0 ? 0.04 * (e.volume / 100) : 0, at, 0.003);
}
$('sound').addEventListener('change', () => {
  if (audio && !$('sound').checked) gain.gain.value = 0;
  if (audio && $('sound').checked) audio.resume();
});

// ---- connection, motion, touch ---------------------------------------------------------------

$('connected').addEventListener('change', (e) => post({ type: 'connect', on: e.target.checked }));
$('moving').addEventListener('change', (e) => post({ type: 'motion', on: e.target.checked }));
$('restart').addEventListener('click', () => post({ type: 'restart' }));
$('restart-boot').addEventListener('click', () => post({ type: 'restart', fromBoot: true }));
document.querySelectorAll('[data-swipe]').forEach((b) =>
  b.addEventListener('click', () => post({ type: 'swipe', right: b.dataset.swipe === '1' })));

// The pad: a click is a short tap, a hold of 400 ms or more a long one; up to five taps, sent 0.7 s
// after the last as the ring's tap code (bit i set = tap i was long).
const pad = $('pad');
const taps = [];
let pressedAt = 0, sendTimer;
pad.addEventListener('pointerdown', (e) => {
  e.preventDefault();
  pad.setPointerCapture(e.pointerId);
  pressedAt = performance.now();
  pad.classList.add('held');
  clearTimeout(sendTimer);
});
pad.addEventListener('pointerup', () => {
  if (!pressedAt) return;
  pad.classList.remove('held');
  taps.push(performance.now() - pressedAt >= 400);
  pressedAt = 0;
  pad.textContent = taps.map((long) => (long ? '—' : '•')).join(' ');
  if (taps.length === 5) flushTaps();
  else sendTimer = setTimeout(flushTaps, 700);
});
pad.addEventListener('keydown', (e) => {
  if (e.key !== 'Enter' && e.key !== ' ') return;
  e.preventDefault();
  taps.push(e.shiftKey);
  pad.textContent = taps.map((long) => (long ? '—' : '•')).join(' ');
  clearTimeout(sendTimer);
  sendTimer = setTimeout(flushTaps, 700);
});
function flushTaps() {
  clearTimeout(sendTimer);
  if (!taps.length) return;
  const code = taps.reduce((c, long, i) => c | (long ? 1 << i : 0), 0);
  post({ type: 'tap', code, length: taps.length });
  taps.length = 0;
  setTimeout(() => { pad.textContent = 'Tap here'; }, 400);
}

// ---- command groups --------------------------------------------------------------------------

function slider(group, label, { min, max, value, step = 1, unit = '' }) {
  const row = document.createElement('label');
  row.className = 'slider';
  row.innerHTML = '<span></span><input type="range"><output></output>';
  row.querySelector('span').textContent = label;
  const input = row.querySelector('input');
  Object.assign(input, { min, max, value, step });
  const out = row.querySelector('output');
  const show = () => { out.textContent = `${input.value}${unit}`; };
  input.addEventListener('input', show);
  show();
  group.querySelector('.sliders').append(row);
  return () => Number(input.value);
}

function group(title, note) {
  const g = document.createElement('section');
  g.className = 'group';
  g.innerHTML = '<h2></h2><div class="sliders"></div><div class="buttons"></div>';
  g.querySelector('h2').textContent = title;
  if (note) {
    const p = document.createElement('p');
    p.className = 'note';
    p.textContent = note;
    g.append(p);
  }
  $('groups').append(g);
  return g;
}

function button(g, label, make, { unsupported = false } = {}) {
  const b = document.createElement('button');
  b.type = 'button';
  b.textContent = label;
  if (unsupported) b.className = 'unsupported';
  b.addEventListener('click', () => {
    const out = make();
    (Array.isArray(out[0]) ? out : [out]).forEach((bytes) => send(label, bytes));
  });
  g.querySelector('.buttons').append(b);
}

const STREET = 'Carrer Major';
const navMask = C.DEFAULT_CARDS | 1;

{
  const g = group('Navigation', 'As the app sends it. The firmware draws the off-route pointer only while the bike moves.');
  const angle = slider(g, 'Turn angle', { min: -180, max: 180, value: 90, unit: '°' });
  const metres = slider(g, 'Distance', { min: 0, max: 500, value: 60, step: 5, unit: ' m' });
  // The app's progress: 0 at 95 m or more, 100 at 20 m or less.
  const progress = () => Math.round(Math.max(0, Math.min(100, ((95 - metres()) / 75) * 100)));
  button(g, 'Start', () => [C.turnByTurnIntro(STREET), C.carouselPosition(0, navMask)]);
  button(g, 'Turn', () => C.navAngle({ angle: angle(), progress: progress(), distance: metres(), text: STREET }));
  button(g, 'Turn, then another', () => C.navAngle({ angle: angle(), progress: progress(), distance: metres(),
    nextAngle: -angle(), nextProgress: Math.max(1, progress() - 40), nextDistance: metres() + 40, text: STREET }));
  button(g, 'Off route', () => C.navPointer(angle(), metres(), 'Return to route'));
  button(g, 'Ride to calibrate', () => C.navPointerStandby(metres(), 'Go to GPX start'));
  button(g, 'Arrive', () => [C.navPointerOff(), C.navOff(), C.nav(0, 100, 0, 'Your destination')]);
  button(g, 'Reroute', () => C.navReroute());
  button(g, 'Stop', () => [C.navPointerOff(), C.navOff()]);
}

{
  const g = group('Alerts', 'Notifications ({1,7}): the ring pulses and the display shows the icon and the text.');
  button(g, 'Incoming call', () => C.incomingCall('Incoming call'));
  button(g, 'Rain', () => C.rainAlert('Rain in 20 min'));
  button(g, 'Error', () => C.errorNotification('No GPS'));
  const icon = (type, text) => () => C.notification(type, C.Colour.teal, [200, 50, 100, 10], 3, text);
  button(g, 'Message', icon(C.NotificationType.message, 'Anna: on my way'));
  button(g, 'Home', icon(C.NotificationType.home, 'Home'));
  button(g, 'Work', icon(C.NotificationType.work, 'Work'));
  button(g, 'Clock', icon(C.NotificationType.clock, 'Sunset in 20 min'));
  button(g, 'Horn', icon(C.NotificationType.horn, 'Horn'));
  button(g, 'Stop', icon(C.NotificationType.stop, 'Navigation ended'));
  button(g, 'Alert off', () => C.notificationOff());
}

{
  const g = group('Speedometer and progress',
    'The display shows the speed only on the speed card, with the bike moving: swipe to it, or use "Go to the speed card".');
  const pct = slider(g, 'Gauge', { min: 0, max: 100, value: 60, unit: ' %' });
  const value = slider(g, 'Number', { min: 0, max: 255, value: 140 });
  const done = slider(g, 'Progress', { min: 0, max: 100, value: 40, unit: ' %' });
  button(g, 'Speedometer intro', () => C.speedometerIntro());
  button(g, 'Speedometer', () => C.showSpeedometer(pct(), value()));
  button(g, 'Speedometer off', () => C.speedometerOff());
  button(g, 'Go to the speed card', () => C.carouselPosition(C.CarouselCard.speed, C.DEFAULT_CARDS));
  button(g, 'Fitness intro', () => C.fitnessIntro());
  button(g, 'Progress', () => C.progress(done()));
  button(g, 'Progress off', () => C.progressOff());
}

{
  const g = group('Ring cards', 'The ring asks for a card\'s content every second while it shows it; with "Answer card requests" on, this page answers like the app.');
  const kmh = slider(g, 'Ride speed', { min: 0, max: 60, value: ride.kmh, unit: ' km/h' });
  g.querySelector('input').addEventListener('input', () => { ride.kmh = kmh(); });
  button(g, 'Clock now', () => { const d = new Date(); return C.showClock(d.getHours(), d.getMinutes()); });
  button(g, 'Clock off', () => C.clockOff());
  button(g, 'Battery', () => C.showStateOfCharge());
  for (const [name, card] of [['Clock card', 6], ['Distance card', 2], ['Time card', 3], ['Battery card', 9]]) {
    button(g, name, () => C.carouselPosition(card, C.DEFAULT_CARDS));
  }
}

{
  const g = group('Light');
  const level = slider(g, 'Brightness', { min: 0, max: 100, value: 100, unit: ' %' });
  const ring = slider(g, 'Ring', { min: 0, max: 255, value: 255 });
  button(g, 'On', () => C.frontLight(true));
  button(g, 'Off', () => C.frontLight(false));
  button(g, 'Steady', () => C.frontLightSettings(false, level()));
  button(g, 'Blinking', () => C.frontLightSettings(true, level()));
  button(g, 'Ring brightness', () => C.setBrightness(ring()), { unsupported: true });
}

{
  const g = group('Onboarding and language',
    'The touch onboarding teaches the gestures on the ring itself: follow it on the pad and with the swipes. '
    + 'The language buttons set the clock and the display\'s language ({4,6}), as the app does on connecting.');
  button(g, 'Touch onboarding', () => C.touchOnboarding());
  for (const [label, code] of [['English', 'en'], ['Español', 'es'], ['Français', 'fr'], ['Deutsch', 'de']]) {
    button(g, label, () => C.localization(Date.now() / 1000, code));
  }
}

{
  const g = group('Alarm', 'Turn it on, untick "App connected" and the ring arms itself; tick "Bike moving" to set it off. '
    + 'Tap • — • — • on the pad to disarm it.');
  const seed = [1, 2, 3, 4];
  const code = 0b01010;   // short, long, short, long, short
  button(g, 'Alarm on', () => C.alarmConfigure(seed, code, 5, true));
  button(g, 'Alarm off', () => C.alarmConfigure(seed, code, 5, false));
  button(g, 'Report', () => C.alarmReport());
  button(g, 'Demo: arm', () => C.alarmDemo(C.AlarmDemo.arm));
  button(g, 'Demo: warn', () => C.alarmDemo(C.AlarmDemo.warn, 66));
  button(g, 'Demo: sound', () => C.alarmDemo(C.AlarmDemo.sound));
  button(g, 'Demo: disarm', () => C.alarmDemo(C.AlarmDemo.disarm));
  button(g, 'Demo: off', () => C.alarmDemo(C.AlarmDemo.off));
  button(g, 'Demo as the app sends it', () => C.demo(), { unsupported: true });
}

{
  const g = group('Animations', 'Dashed: the app has them, the firmware refuses them (UNIMPLEMENTED, or FAIL for the app\'s demo).');
  button(g, 'Logo', () => C.logo());
  button(g, 'Low battery', () => C.lowBattery());
  button(g, 'Animations off', () => C.animOff());
  button(g, 'Horn sound', () => C.soundPlay(100, 0, C.hornTrack));
  button(g, 'Heartbeat', () => C.heartbeat(), { unsupported: true });
  button(g, 'Compass', () => C.compass(90), { unsupported: true });
  button(g, 'Pointer with intro', () => [1, 33, ...C.Colour.teal, 0, 90, 0], { unsupported: true });
}

$('custom').addEventListener('submit', (e) => {
  e.preventDefault();
  const clean = $('hex').value.replace(/0x/gi, '').replace(/[^0-9a-f]/gi, '');
  if (clean.length < 4 || clean.length % 2) return log('fw', '!', 'Write whole bytes: at least the service and the command.');
  send('', fromHex(clean));
});
