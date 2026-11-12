// Builds usb-reboot.svg: the recovery reboot, a micro-USB cable plugging into the bottom of the Halo
// and back out, on an 8 s loop. Left, the Halo side-on; right, from above, where the ring runs the
// firmware's charge animation while the cable is in (battery_AnimationsLibrary, AnimationsLibrary.c).
// CSS keyframes only, no script, so it plays in a README <img> and on rehalo.app.
// The app draws the same thing in clients/ios/.../UI/Recovery/UsbRebootIllustration.swift: keep the
// timings and the geometry of both in step.
//
// Usage (from the repo root): node docs/img/usb-reboot.mjs
// Writes docs/img/usb-reboot.svg and site/assets/usb-reboot.svg.
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// Theme.swift tokens + the device's materials.
const C = {
  surface: '#15181D', stroke: '#2A3038', text: '#F2F4F7', accent: '#C6FF3D',
  body: '#22272F', edge: '#363D48', glass: '#0C0E12', seam: '#2B313A',
};

// Timeline, in seconds. The plug clicks in at `click`; the ring fills for 500 ms from `fillStart`,
// retracts for 500 ms to the battery level, pulses, and goes dark at `unplug`.
const T = 8;
const TL = { inStart: 0.5, click: 1.45, fillStart: 1.5, pulses: [2.9, 4.3], unplug: 5.9, outEnd: 6.8 };
const LIT = 15;    // LEDs lit at 60 % (the firmware leaves 23 × 40 / 100 ≈ 9 off)
const OFF = 46;    // how far the plug is pulled out, in plug units

// The firmware's charge colour for LED j in fill order: red to green over the first 60 % of the lap.
const chargeColor = (j) => {
  const f = (j + 0.5) / 24;
  return `hsl(${(f < 0.6 ? (120 * f) / 0.6 : 120).toFixed(0)}, 92%, 56%)`;
};
// Fill order j starts at 6 o'clock (LED 12) and goes clockwise.
const ledIndex = (j) => (j + 12) % 24;

const pct = (s) => Math.min(100, Math.max(0, +((s / T) * 100).toFixed(3)));
function kf(name, stops) {
  const pts = stops.map(([s, css, ease]) => [pct(s), css, ease]).sort((a, b) => a[0] - b[0]);
  if (pts[0][0] > 0) pts.unshift([0, pts[0][1]]);
  if (pts.at(-1)[0] < 100) pts.push([100, pts.at(-1)[1]]);
  return `@keyframes ${name}{${pts.map(([p, css, ease]) => `${p}%{${css}${ease ? `;animation-timing-function:${ease}` : ''}}`).join('')}}`;
}
const E = 0.004;

function keyframes() {
  const out = [];
  const fillEnd = TL.fillStart + 0.5;
  for (let j = 0; j < 24; j++) {
    const on = TL.fillStart + (j / 24) * 0.5;
    const s = [[0, 'opacity:0'], [on, 'opacity:0'], [on + E, 'opacity:1']];
    if (j >= LIT) {
      const off = fillEnd + ((23 - j) / (24 - LIT)) * 0.5;
      s.push([off, 'opacity:1'], [off + E, 'opacity:0']);
    } else {
      s.push([TL.unplug, 'opacity:1'], [TL.unplug + 0.15, 'opacity:0']);
    }
    out.push(kf(`u-l${j}`, s));
  }
  // The pulse: one LED every 50 ms, with a dimmer LED either side.
  for (let j = 0; j < LIT; j++) {
    const s = [[0, 'opacity:0']];
    for (const P of TL.pulses) {
      const c = P + j * 0.05;
      s.push([c - 0.1, 'opacity:0'], [c - 0.05, 'opacity:.3'], [c, 'opacity:.8'], [c + 0.05, 'opacity:.3'], [c + 0.1, 'opacity:0']);
    }
    out.push(kf(`u-p${j}`, s));
  }
  // OLED battery icon while charging; its bar steps up and starts over, like chargingProgress.
  out.push(kf('u-oled', [[0, 'opacity:0'], [TL.click, 'opacity:0'], [TL.click + 0.05, 'opacity:1'], [TL.unplug, 'opacity:1'], [TL.unplug + 0.15, 'opacity:0']]));
  const bar = [[0, 'transform:scaleX(0)']];
  let v = 0;
  for (let t = TL.click; t < TL.unplug; t += 0.45) {
    bar.push([t, `transform:scaleX(${v})`]);
    v = v >= 1 ? 0.2 : +(v + 0.2).toFixed(1);
    bar.push([t + E, `transform:scaleX(${v})`]);
  }
  bar.push([TL.unplug, `transform:scaleX(${v})`], [TL.unplug + E, 'transform:scaleX(0)']);
  out.push(kf('u-bar', bar));
  // Light leaking out of the glass in the side view.
  const g = [[0, 'opacity:0'], [TL.fillStart, 'opacity:0'], [TL.fillStart + 0.35, 'opacity:.9'], [fillEnd + 0.5, 'opacity:.55']];
  for (const P of TL.pulses) g.push([P, 'opacity:.55'], [P + 0.35, 'opacity:.9'], [P + 0.8, 'opacity:.55']);
  g.push([TL.unplug, 'opacity:.55'], [TL.unplug + 0.15, 'opacity:0']);
  out.push(kf('u-glow', g));
  out.push(kf('u-plug', [
    [0, `transform:translateY(${OFF}px)`],
    [TL.inStart, `transform:translateY(${OFF}px)`, 'cubic-bezier(.45,0,.2,1)'],
    [TL.click, 'transform:translateY(0px)'],
    [TL.unplug, 'transform:translateY(0px)', 'cubic-bezier(.5,0,.6,1)'],
    [TL.outEnd, `transform:translateY(${OFF}px)`],
  ]));
  out.push(kf('u-click', [
    [0, 'opacity:0;transform:scale(.4)'],
    [TL.click, 'opacity:0;transform:scale(.4)'],
    [TL.click + 0.01, 'opacity:1;transform:scale(.5)'],
    [TL.click + 0.45, 'opacity:0;transform:scale(1.7)'],
  ]));
  return out;
}

const f2 = (n) => +n.toFixed(2);
// LED i (0 at 12 o'clock, clockwise), 15° wide with a 1.5° gap either side.
function arc(i, r) {
  const a0 = ((i * 15 + 1.5) * Math.PI) / 180, a1 = ((i * 15 + 13.5) * Math.PI) / 180;
  return `M${f2(r * Math.sin(a0))} ${f2(-r * Math.cos(a0))}A${r} ${r} 0 0 1 ${f2(r * Math.sin(a1))} ${f2(-r * Math.cos(a1))}`;
}
// The static style is the still frame (plugged in, charging) shown with Reduce Motion.
const an = (name, rest = '', cls = '') => `class="an${cls ? ' ' + cls : ''}" style="animation-name:${name}${rest ? ';' + rest : ''}"`;
const NS = 'vector-effect="non-scaling-stroke"';

// The top face in its own units (radius 86, LEDs at 62), centred on 0,0.
function face() {
  const base = [], lit = [], pulse = [];
  for (let j = 0; j < 24; j++) {
    const d = arc(ledIndex(j), 62);
    base.push(`<path d="${d}"/>`);
    lit.push(`<path d="${d}" stroke="${chargeColor(j)}" ${an(`u-l${j}`, `opacity:${j < LIT ? 1 : 0}`)}/>`);
    if (j < LIT) pulse.push(`<path d="${d}" ${an(`u-p${j}`, 'opacity:0')}/>`);
  }
  return `<circle r="86" fill="${C.body}" stroke="${C.edge}" stroke-width="1.2" ${NS}/>
<circle r="79" fill="${C.glass}"/>
<g fill="none" stroke-width="11" stroke="${C.text}" stroke-opacity=".09">${base.join('')}</g>
<g fill="none" stroke-width="11" filter="url(#u-led)">${lit.join('')}</g>
<g fill="none" stroke-width="11" stroke="#fff">${pulse.join('')}</g>
<rect x="-19" y="-10.5" width="38" height="21" rx="3" fill="#050608" stroke="#262B33" stroke-width="1" ${NS}/>
<g ${an('u-oled', 'opacity:1')}>
<rect x="-9.5" y="-4.5" width="17" height="9" rx="1.6" fill="none" stroke="${C.text}" stroke-width="1.3" ${NS}/>
<rect x="7.8" y="-2" width="2" height="4" rx=".6" fill="${C.text}"/>
<g transform="translate(-7.8 0)"><rect y="-2.8" width="13.6" height="5.6" rx=".8" fill="${C.text}" ${an('u-bar', 'transform:scaleX(.6)')}/></g>
</g>`;
}

const label = 'A micro-USB cable plugs into the bottom of the Halo and its ring lights up';
const svg = `<!-- Generated by docs/img/usb-reboot.mjs; edit that and run it again. -->
<svg viewBox="0 0 340 200" width="340" height="200" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="${label}">
<title>${label}</title>
<style>
.an{animation-duration:${T}s;animation-iteration-count:infinite;animation-timing-function:linear;animation-fill-mode:both;transform-box:view-box;transform-origin:0 0}
@media (prefers-reduced-motion:reduce){.an{animation:none!important}}
${keyframes().join('\n')}
</style>
<defs>
<filter id="u-led" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="2.4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
<filter id="u-soft" x="-30%" y="-80%" width="160%" height="260%"><feGaussianBlur stdDeviation="5"/></filter>
<linearGradient id="u-light" x1="0" x2="1" y1="0" y2="0"><stop offset="0" stop-color="hsl(8, 92%, 56%)"/><stop offset=".5" stop-color="hsl(55, 92%, 56%)"/><stop offset="1" stop-color="hsl(120, 92%, 56%)"/></linearGradient>
</defs>
<rect x=".5" y=".5" width="339" height="199" rx="21.5" fill="${C.surface}" stroke="${C.stroke}"/>
<rect x="44" y="70" width="102" height="9" rx="4.5" fill="url(#u-light)" filter="url(#u-soft)" ${an('u-glow', 'opacity:.55')}/>
<g transform="translate(95 106) scale(.9)"><g ${an('u-plug')}>
<path d="M0 37V170" stroke="#4C5563" stroke-width="5.5" stroke-linecap="round" fill="none"/>
<path d="M-7 27.5H7L4.6 37H-4.6Z" fill="#30363F"/>
<rect x="-11" y="0" width="22" height="28" rx="4.5" fill="#3A424D" stroke="#56606D" stroke-width="1"/>
<rect x="-8.5" y="1.6" width="17" height="1.2" rx=".6" fill="#4C5662"/>
<path d="M-6 17.5H6M-6 20.5H6M-6 23.5H6" stroke="#2C323B" stroke-width="1.2" stroke-linecap="round"/>
<rect x="-7.5" y="-11" width="15" height="11.5" rx="1.4" fill="#C2CAD4"/>
<rect x="-5.6" y="-9" width="11.2" height="3" rx=".8" fill="#8D97A4"/>
<rect x="-4" y="-4.4" width="2" height="1.6" rx=".4" fill="#7A8491"/>
<rect x="2" y="-4.4" width="2" height="1.6" rx=".4" fill="#7A8491"/>
</g></g>
<rect x="31" y="82" width="128" height="24" rx="9" fill="${C.body}" stroke="${C.edge}" stroke-width="1.2"/>
<path d="M36 94.5H154" stroke="${C.seam}" stroke-width="1"/>
<rect x="38" y="77" width="114" height="7" rx="3.5" fill="${C.glass}" stroke="${C.edge}" stroke-width="1"/>
<rect x="85.5" y="101.5" width="19" height="4.5" rx="1.2" fill="#040506"/>
<g transform="translate(95 106)"><g ${an('u-click', 'opacity:0')}><ellipse rx="15" ry="4.5" fill="none" stroke="${C.accent}" stroke-width="2"/></g></g>
<path d="M181 40V160" stroke="${C.stroke}" stroke-width="1.2" stroke-dasharray="2 5" stroke-linecap="round"/>
<g transform="translate(252 100) scale(.744)">${face()}</g>
</svg>
`;

for (const out of ['docs/img/usb-reboot.svg', 'site/assets/usb-reboot.svg']) {
  writeFileSync(join(root, out), svg);
  console.log(`${out}: ${svg.length} bytes`);
}
