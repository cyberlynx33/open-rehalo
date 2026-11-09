// The bytes the iOS app sends, for the preview's buttons. Mirrors
// clients/ios/SH2Protocol/Sources/SH2Nav/Commands.swift (same names, same layouts).

export const Colour = {
  teal: [128, 255, 128],
  white: [0, 0, 255],
  turn: [67, 255, 255],        // navigation green
  caution: [38, 234, 249],
  warning: [253, 237, 255],
  offPath: [30, 255, 255],     // the pointer back to a route
  progress: (p) => [Math.min(255, 17 + Math.floor((p / 100) * 50)), 255, 255],
};

export const CarouselCard = {
  navigation: 0, goal: 1, distance: 2, time: 3, speed: 4, calories: 5, clock: 6, avgSpeed: 7, co2: 8, battery: 9,
};

// The app's cards: distance, time, speed, calories, clock, average speed, battery (NavDirector.defaultCards).
export const DEFAULT_CARDS = 0x02fc;

const u16 = (v) => [(v >> 8) & 0xff, v & 0xff];

export function metric4(metres, metric = true) {
  const value = metric ? metres : Math.floor(Math.round(metres * 3.2808399 * 10) / 10 + 0.5);
  const v = Math.max(0, Math.round(value)) & 0x7fffffff;
  return [((v >>> 24) & 0xff) | (metric ? 0 : 0x80), (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff];
}

export function angle16(degrees) {
  const v = Math.max(-32768, Math.min(32767, Math.round(degrees))) & 0xffff;
  return [v >> 8, v & 0xff];
}

// ISO-8859-1, at most 29 characters (the firmware copies 30 bytes), NUL-terminated.
export function navText(text, header) {
  const limit = Math.min(80 - header - 1, 29);
  const plain = text.normalize('NFC')
    .replace(/[‘’‚′]/g, "'").replace(/[“”„]/g, '"')
    .replace(/[‐‑–—−]/g, '-').replace(/…/g, '...');
  return [...plain].slice(0, limit).map((ch) => (ch.codePointAt(0) <= 0xff ? ch.codePointAt(0) : 0x3f)).concat(0);
}

// ---- light -----------------------------------------------------------------------------------

export const frontLight = (on, external = false) => [1, 4, on ? 1 : 0, external ? 1 : 0];
export const frontLightSettings = (blinking, brightness, blinkingLocked = false, silenceRocker = false) =>
  [1, 16, blinking ? 1 : 0, brightness, blinkingLocked ? 1 : 0, silenceRocker ? 1 : 0];
export const setBrightness = (v) => [1, 15, v];

// ---- display widgets -------------------------------------------------------------------------

export const logo = () => [1, 0];
export const demo = () => [1, 25];
export const animOff = () => [1, 14];
export const lowBattery = () => [1, 21, 0];
export const touchOnboarding = () => [1, 37];
export const showStateOfCharge = () => [1, 31];
export const speedometerIntro = () => [1, 26];
export const speedometerOff = () => [1, 19];
export const showSpeedometer = (percentage, speed, metric = true) => [1, 18, percentage, speed, metric ? 0 : 1];
export const fitnessIntro = (colour = Colour.teal, second = Colour.white, value = 0) => [1, 27, ...colour, ...second, ...u16(value)];
export const progress = (percentage, periodMs = 2000, first = Colour.teal, second = Colour.white, fitness = false) =>
  [1, 5, ...first, ...second, ...u16(periodMs), percentage, fitness ? 1 : 0];
export const progressOff = () => [1, 6];
export const heartbeat = (first = Colour.teal, second = Colour.white, a = 1000, b = 1000, c = 60, d = 0) =>
  [1, 9, ...first, ...second, ...u16(a), ...u16(b), ...u16(c), ...u16(d)];
export const compass = (heading, colour = Colour.teal) => [1, 11, ...colour, ...u16(heading)];

export function showClock(hour, minute, { hourColour = Colour.teal, minuteColour = Colour.white, durationMs = 5000,
  fade = true, intro = false, pulse = false, is24h = true } = {}) {
  return [1, 28, hour, ...hourColour, minute, ...minuteColour, ...u16(durationMs),
    fade ? 1 : 0, intro ? 1 : 0, pulse ? 1 : 0, is24h ? 1 : 0];
}
export const clockOff = () => [1, 29];

// ---- carousel --------------------------------------------------------------------------------

const carouselHeader = (card, mask) => [1, 35, card, mask & 0xff, mask >> 8, 0, 0];
export const carouselMask = (mask) => carouselHeader(CarouselCard.navigation, mask);
export const carouselPosition = (index, mask) => (mask === undefined ? [1, 36, index] : [1, 36, index, mask & 0xff, mask >> 8, 0, 0]);
export const carouselClock = (mask, hour, minute, is24h = true) =>
  [...carouselHeader(CarouselCard.clock, mask), hour, 0, 0, 220, minute, 143, 219, 198, 0x13, 0x88, 1, 1, 1, is24h ? 1 : 0];
export const carouselBattery = (mask) => carouselHeader(CarouselCard.battery, mask);
export function carouselSpeed(mask, kmh, metric = true) {
  const moving = kmh >= 5;
  const pct = moving ? Math.min(100, Math.round((kmh / 40) * 100)) : 0;
  const speed = moving ? Math.min(255, Math.round(metric ? kmh : kmh / 1.609344)) : 0;
  return [...carouselHeader(CarouselCard.speed, mask), pct, speed, metric ? 0 : 1];
}
export const carouselDistance = (mask, metres, metric = true) => [...carouselHeader(CarouselCard.distance, mask), ...metric4(metres, metric)];
export const carouselTime = (mask, seconds) => [...carouselHeader(CarouselCard.time, mask), ...u16(Math.min(65535, Math.max(0, seconds)))];
export const carouselAvgSpeed = (mask, averageKmh, currentKmh, metric = true) => [
  ...carouselHeader(CarouselCard.avgSpeed, mask), ...metric4(averageKmh * 1000, metric), ...metric4(currentKmh * 1000, metric),
  ...Colour.caution, ...Colour.white, ...Colour.turn];
export function carouselNavigationCard(mask, distance, angle = 0, text = '', metric = true) {
  const bytes = carouselHeader(CarouselCard.navigation, mask);
  if (distance === undefined) return bytes;
  return [...bytes, ...metric4(distance, metric), ...angle16(angle), 0, 0, 220, ...navText(text, 9)];
}

// ---- navigation ------------------------------------------------------------------------------

export const turnByTurnIntro = (title, mode = 2) => [1, 32, mode, ...navText(title, 3)];
export const navOff = () => [1, 3];
export const navReroute = () => [1, 2];
export function navAngle({ colour = Colour.turn, angle, progress: p, sameTurn = false, nextColour = Colour.turn,
  nextAngle = 0, nextProgress = 0, distance, nextDistance = 0, text = '', metric = true }) {
  return [1, 17, ...colour, ...angle16(angle), ((p + (sameTurn ? 128 : 0)) & 0xff), ...nextColour, ...angle16(nextAngle),
    nextProgress & 0xff, ...metric4(distance, metric), ...metric4(nextDistance, metric), ...navText(text, 22)];
}
export const nav = (stepType, p, distance, text, metric = true, colour = Colour.turn) =>
  [1, 1, ...colour, stepType, p & 0xff, ...metric4(distance, metric), ...navText(text, 11)];
export const navPointer = (angle, distance, text, colour = Colour.offPath, metric = true) =>
  [1, 22, ...colour, ...angle16(angle), ...metric4(distance, metric), ...navText(text, 11)];
export const navPointerOff = () => [1, 23];
export const navPointerStandby = (distance, text, colour = Colour.progress(0), metric = true) =>
  [1, 24, ...colour, ...metric4(distance, metric), ...navText(text, 9)];

// ---- notifications ---------------------------------------------------------------------------

export const NotificationType = { call: 0, message: 1, weather: 32, horn: 64, clock: 65, home: 66, work: 67, stop: 68, error: 69 };

export function notification(type, colour, timing, repeat, text) {
  const header = [1, 7, ...colour, colour[0], colour[1], 0, ...timing.flatMap(u16), repeat, type];
  return [...header, ...navText(text, header.length)];
}
export const notificationOff = () => [1, 8];
export const incomingCall = (text) => notification(NotificationType.call, [143, 219, 198], [100, 256, 100, 0], 60, text);
export const rainAlert = (text) => notification(NotificationType.weather, [170, 220, 255], [200, 50, 100, 10], 10, text);
export const errorNotification = (text = 'An error occurred') => notification(NotificationType.error, [253, 237, 255], [200, 50, 100, 10], 3, text);

// ---- device ----------------------------------------------------------------------------------

// {4,6}: the clock and the display's language. [4,6] + unix seconds (8 bytes, little-endian) + "en"/"fr"/"es"/"de".
export function localization(unixSeconds, language) {
  const t = [];
  let v = BigInt(Math.floor(unixSeconds));
  for (let i = 0; i < 8; i++) { t.push(Number(v & 0xffn)); v >>= 8n; }
  return [4, 6, ...t, ...[...language.slice(0, 2)].map((c) => c.charCodeAt(0) & 0x7f)];
}

// ---- alarm -----------------------------------------------------------------------------------

export const alarmReport = () => [3, 0];
export const alarmGetSeed = () => [3, 1];
// How the app arms and disarms: [3,3, seed(4), tapCode, tapLength, armed, vigilant]. Bit i of the
// tap code = tap i is long. The firmware doesn't check the seed.
export const alarmConfigure = (seed, tapCode, tapLength, armed, vigilant = true) =>
  [3, 3, ...seed, tapCode, tapLength, armed ? 1 : 0, vigilant ? 1 : 0];
// {1,25}: the alarm's animations on demand (AlarmTask's alarmDemo). The app sends no state, which the
// firmware refuses.
export const AlarmDemo = { off: 0, arm: 1, disarm: 2, warn: 3, sound: 4 };
export const alarmDemo = (state, progress = 0) => (state === AlarmDemo.warn ? [1, 25, state, progress] : [1, 25, state]);

// ---- sound -----------------------------------------------------------------------------------

export const soundPlay = (volume, repeat, track) => [2, 0, Math.min(100, volume), repeat, ...track];
export const soundStop = () => [2, 1];
export const hornTrack = [0x01, 0xd2, 0x00, 0xfa, 0x00, 0x00, 0x00, 0x64, 0x01, 0xd2, 0x01, 0xf4, 0x00, 0x00, 0x00, 0x00];
