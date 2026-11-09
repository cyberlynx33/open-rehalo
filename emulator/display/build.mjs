// Builds halo-display: the SmartHalo 2 firmware's own display code (STM32 side), compiled for this
// computer with the simulator in src/. Nothing from the firmware is kept in this repo: it's read from
// your copy at build time.
//
//   SH2_STM_FIRMWARE  the firmware's smart_halo-smarthalo2-stm-firmware-* folder
//                     (default: reference/smarthalo-firmware/smart_halo-smarthalo2-stm-firmware-b172e75c4188)
//   CC                the C compiler (default: cc). clang, gcc and `zig cc` work.
//
// node emulator/display/build.mjs [--quiet]
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');

export const DEFAULT_FIRMWARE = path.join(repo,
  'reference/smarthalo-firmware/smart_halo-smarthalo2-stm-firmware-b172e75c4188');
export const BINARY = path.join(here, 'build', process.platform === 'win32' ? 'halo-display.exe' : 'halo-display');

// The firmware files compiled as they are, with the names a few of them must call through the
// simulator instead (src/quirks.c says why).
export const FIRMWARE_SOURCES = [
  { file: 'Src/SmartHaloOS/GraphicsTask.c' },
  { file: 'Src/SmartHaloOS/AnimationsLibrary.c' },
  { file: 'Src/SmartHaloOS/OLEDLibrary.c' },
  { file: 'Src/Peripherals/OLEDDriver.c' },
  { file: 'Src/SmartHaloOS/SubscriptionHelper.c' },
  { file: 'Src/Applications/RideTask.c', rename: ['startAnimation_GraphicsTask'] },
  { file: 'Src/Applications/PersonalityTask.c' },
  { file: 'Src/Applications/NightLightTask.c' },
  { file: 'Src/SmartHaloOS/SoundTask.c' },
  { file: 'Src/Applications/AlarmTask.c' },
  { file: 'Src/assets.c' },
];

export function firmwareDir() {
  return path.resolve(process.env.SH2_STM_FIRMWARE || DEFAULT_FIRMWARE);
}

export function build({ quiet = false } = {}) {
  const fw = firmwareDir();
  if (!fs.existsSync(path.join(fw, 'Src/SmartHaloOS/GraphicsTask.c'))) {
    throw new Error(`SmartHalo 2 STM firmware not found at ${fw}. Set SH2_STM_FIRMWARE to your copy's ` +
      'smart_halo-smarthalo2-stm-firmware-* folder.');
  }
  const cc = process.env.CC || 'cc';
  const objDir = path.join(path.dirname(BINARY), 'obj');
  fs.mkdirSync(objDir, { recursive: true });
  const includes = [
    path.join(here, 'include'),
    path.join(fw, 'Inc'),
    path.join(fw, 'Inc/SmartHaloOS'),
    path.join(fw, 'Inc/Applications'),
    path.join(fw, 'Inc/Peripherals'),
    path.join(fw, 'assets'),
  ].flatMap((d) => ['-I', d]);
  // The ring's compiler is arm-none-eabi-gcc: enums as small as their values (the bare-metal AAPCS)
  // and unsigned char. Both matter here: the app's payloads are cast to structs with enum fields.
  const flags = ['-std=gnu11', '-O1', '-g', '-w', '-fno-strict-aliasing', '-fshort-enums', '-funsigned-char',
    '-D_FORTIFY_SOURCE=0', '-DSH2_SIMULATOR=1', '-include', path.join(here, 'include/sim-prelude.h'), ...includes];

  const units = [
    ...fs.readdirSync(path.join(here, 'src')).filter((f) => f.endsWith('.c')).map((f) => ({ src: path.join(here, 'src', f) })),
    ...FIRMWARE_SOURCES.map(({ file, rename = [] }) => ({ src: path.join(fw, file), defines: rename.map((n) => `-D${n}=sim_${n}`) })),
  ];
  const objects = units.map(({ src, defines = [] }) => {
    const obj = path.join(objDir, `${path.basename(src, '.c')}.o`);
    if (!quiet) console.log(`cc ${path.relative(repo, src)}`);
    execFileSync(cc, [...flags, ...defines, '-c', src, '-o', obj], { stdio: quiet ? 'pipe' : 'inherit' });
    return obj;
  });
  execFileSync(cc, [...objects, '-lm', '-lpthread', '-o', BINARY], { stdio: quiet ? 'pipe' : 'inherit' });
  if (!quiet) console.log(`→ ${path.relative(repo, BINARY)}`);
  return BINARY;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    build({ quiet: process.argv.includes('--quiet') });
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}
