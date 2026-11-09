# emulator

Two software models of the SmartHalo 2, for working without the ring:

- **Recovery** (`src/sh2-device.mjs`): the nRF52's authentication and the STM32's file system and
  standby, enough to run the password recovery end to end. `node emulator/run-recovery.mjs`.
- **Display preview** (`display/`, `preview/`): the ring's own display firmware (LED ring, OLED, front
  light, buzzer) compiled for your computer, and a local web page of its own that shows it live,
  drawn the way the website draws its recordings (`preview/halo-view.js`, a copy of that drawing; the
  website isn't involved). Send it the app's commands, tap and swipe the ring, move the bike.

## Display preview

```bash
export SH2_STM_FIRMWARE=/path/to/smart_halo-smarthalo2-stm-firmware-b172e75c4188   # your copy
node emulator/preview/server.mjs      # builds on the first run, then http://127.0.0.1:8090
```

It needs a C compiler (`cc`, or set `CC`: clang, gcc and `zig cc` work) and your copy of the
[firmware source](https://github.com/smarthalo-community/smarthalo-firmware): its
`smart_halo-smarthalo2-stm-firmware-*` folder, by default
`reference/smarthalo-firmware/smart_halo-smarthalo2-stm-firmware-b172e75c4188`. Nothing from the
firmware is kept in this repo; `display/build/` is ignored. `PORT` changes the port.

The page has the app's commands as buttons (navigation, alerts, speedometer and progress, ring cards,
light, alarm, onboarding and language), any command in hex, a tap pad and swipes, "App connected" and
"Bike moving", and a log of what the firmware replies and notifies. With "Answer card requests like
the app" on, it answers the ring's carousel the way the app does. "Restart from power-on" shows the
boot screen; otherwise the ring starts booted and connected.

### How it works

`display/build.mjs` compiles these firmware files as they are, from your copy:

| File | What it does here |
| --- | --- |
| `GraphicsTask.c`, `AnimationsLibrary.c` | The LED animations and the display's queue and transitions |
| `OLEDLibrary.c`, `OLEDDriver.c`, `assets.c` | Fonts, images, layout, and the SSD1305 driver |
| `RideTask.c` | Navigation, notifications, speedometer, progress, the ring's cards |
| `PersonalityTask.c` | Logo, clock, low battery, taps on the display, onboarding, start-up screen |
| `NightLightTask.c` | The front light |
| `AlarmTask.c` | The alarm |
| `SoundTask.c` | The buzzer's tracks |
| `SubscriptionHelper.c` | Event subscriptions between tasks |

The simulator in `display/src/` stands in for the rest:

- `rtos.c`: FreeRTOS. Every task runs on its own thread, one at a time, on a virtual 1 ms tick; timers
  fire on their tick. A task that never blocks is named and stopped after 3 s.
- `comm.c`: the BLE link (`CommunicationTask.c`): the app's commands reach the handlers the firmware
  assigned; replies and notifications go out. The simulator is always paired and authenticated.
- `devices.c`: the hardware. The LEDs as the animations hand them to the driver; a model of the SSD1305
  that the real `OLEDDriver.c` writes over SPI, with the bus's time on the wire (5 MHz); the front
  light; the buzzer.
- `sensors.c`: the touch pad (taps reported as `SensorsTask.c` does: tap by tap, long after 240 ms,
  ended 720 ms after the last), swipes, and the accelerometer while the bike moves.
- `stubs.c`: the rest of the system: battery at 80 % and 3.9 V, not charging, board revision 5, files
  in memory, the language command `{4,6}`.
- `quirks.c`: where the firmware relies on the STM32 itself (see below).

It compiles with `-fshort-enums -funsigned-char`, like `arm-none-eabi-gcc`: the app's payloads are cast
to structs with enum fields.

`halo-display` speaks lines on stdin and stdout (the protocol is at the top of `display/src/main.c`);
`src/halo-display.mjs` wraps it for Node, and `preview/server.mjs` streams it to the page.

### How faithful it is

Checked in `test/halo-display.test.mjs`:

- A clock drawn by the simulator is byte for byte a frame the website recorded from the firmware.
- The battery animation's LED frames are, in order, frames of `site/firmware.js`, which `site/test/`
  checks against the original C.

Not modelled, or only approximated:

- **Time.** Tasks don't take time to compute, only to wait and to send to the display. Animations keep
  their timing; how long the CPU takes doesn't show.
- **Sensors.** No light sensor (the LEDs stay at full brightness), no compass, a fixed battery level.
  The accelerometer only says "moving" or "still".
- **`SystemUtilitiesTask.c`.** Not built: `{1,31}` shows the battery on the ring but not the battery
  picture on the display; `{4,1}` and the other device commands answer UNIMPLEMENTED.
- **Address 0.** For the fitness intro, `RideTask.c` hands `GraphicsTask.c` a NULL payload that it
  reads. On the ring that reads the boot flash; `quirks.c` gives it the start of a vector table, whose
  handler addresses are guesses.
- **64-bit.** `long` and pointers are wider than on the ring. The payloads use fixed-size types, so
  this shouldn't show.

### Found with it

- `{1,9}` heartbeat, `{1,11}` compass, `{1,15}` ring brightness and `{1,33}` pointer with intro have no
  handler: the firmware answers UNIMPLEMENTED.
- `{1,25}` demo needs a state byte (`AlarmTask.c`'s alarm demo); the app's `[1,25]` alone gets FAIL.
- The speedometer's number shows on the speed card only while the bike moves, next to "km/h" or "mph".
- `{1,37}` touch onboarding needs no payload: it walks through the gestures, in the display's language.
