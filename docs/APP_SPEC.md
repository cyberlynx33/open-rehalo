# rehalo — native iOS app spec

Goal: bring the features of the official SmartHalo app (`bike.smarthalo.app`) to a native SwiftUI app,
on top of `SH2Protocol` (BLE) + `SH2Server` (optional self-hosted server). This spec is the
implementation map: each **module** is a separate unit of work.

The app's display name is **rehalo** and the current version is **0.1.1**, a patch on 0.1.0, the first public release.
The milestones below keep the internal 2.x version numbers they were built under. Turn-by-turn
navigation has shipped (M3, M8).

Derived by reverse engineering the official app: its feature modules (onboarding, assistant/display,
guidance/navigation, fitness/rides, alarm, sound, touch, device/DFU, account/Strava) and the full BLE
command catalog.

## BLE command catalog (ground truth)

Service 0 = auth · 1 = UI/display · 2 = sound · 3 = alarm · 4 = device. `{service, cmd}`:

- **auth (0):** getVersions{0,0} getPeriphPubKey{0,1} setCentralPubKey{0,2} authenticate{0,3}
  setPassword{0,4}  *(the app reads the seed through alarm getSeed{3,1}; the nRF auth service also
  exposes getSeed{0,6}/resetPassword{0,7}, which recovery uses)*
- **display (1):** logo{1,0} nav{1,1} navReroute{1,2} navOff{1,3} frontlight{1,4} progress{1,5}
  progressOff{1,6} notif{1,7} notifOff{1,8} hb{1,9} hbOff{1,10} compass{1,11} compassOff{1,12}
  disconnect{1,13} animOff{1,14} setBrightness{1,15} frontlightSettings{1,16} navAngle{1,17}
  speedometer{1,18} speedometerOff{1,19} roundabout{1,20} lowBat{1,21} navPointer{1,22}
  navPointerOff{1,23} navPointerStandby{1,24} demo{1,25} speedometerIntro{1,26} fitnessIntro{1,27}
  clock{1,28} clockOff{1,29} frontExternalToggle{1,30} showStateOfCharge{1,31} turnByTurnIntro{1,32}
  pointerWithIntro{1,33} roundaboutOled{1,34} carousel{1,35} carouselPosition{1,36} touchOnboarding{1,37}
- **sound (2):** play{2,0} stop{2,1} touchSounds{2,2}
- **alarm (3):** report{3,0} getSeed{3,1} arm{3,2} setConfig{3,3}
- **device (4):** enterBootloader{4,0} getState{4,1} setName{4,2} compassCalibrate{4,3} shutdown{4,4}
  getSerial{4,5} localization{4,6} stmDfuCrc{4,7} stmDfuData{4,8} stmDfuInstall{4,9}
  forceInstallGolden{4,10}

## Baseline (v0.5.0)

Onboarding (server-login or BLE-only skip), `SH2Server` client + `AuthStore` + `AppSettings`,
Keychain tokens, rides list, recovery flow (`.needsReboot` + `reconnectAndFinish`), live log console,
front light (on/off/blink/brightness), ring effects (clock/battery/speedometer demo + animations off),
device rename, basic alarm (arm toggle + report). Commands present: see `Commands.swift`.

---

## Modules

### M1 — Display & Assistant (ring widgets / carousel)
A rich **Display** screen that drives every service-1 display command. Add the missing `Commands`
(logo, demo, compass/compassOff, progress/progressOff, hb/hbOff, lowBat, frontExternalToggle,
speedometerOff, clockOff, speedometerIntro, fitnessIntro, turnByTurnIntro, pointerWithIntro,
roundabout/roundaboutOled, carousel{1,35}+carouselPosition{1,36}) with byte layouts taken from the
reverse engineered payloads; lock them with `CommandsTests`. UI: toggle/trigger each widget, a **carousel
editor** (pick which widgets show + order), a demo runner. Reuse the existing ring-effects section.

### M2 — Alarm (full) + Sound + Touch
Complete **Security** screen: arm and disarm with `configureAlarm`, `setConfig{3,3}` (tap code, armed,
vigilant; sent on every connection and every change, as the official app does; `{3,2}` is never sent),
parse `report{3,0}`.
**Sound:** play{2,0}/stop{2,1}/touchSounds{2,2} toggle. **Touch:** touchOnboarding{1,37} + touch
settings. Standby arming needs an authenticated link.

### M3 — Navigation with GPX route following
Load a GPX route and have the ring guide you along it, like the official app did.
- **GPX import:** a Files picker → parse the GPX (`trk/trkseg/trkpt` lat/lon/ele). Reuse this parser
  for ride GPX in M5.
- **Live following:** CoreLocation (add `NSLocationWhenInUseUsageDescription` to Info.plist). Track the
  rider along the route: nearest point ahead, bearing to the next point, upcoming turns (significant
  heading changes), distance-to-turn, and route progress %.
- **Ring guidance (BLE):** add + drive the nav commands — navPointer{1,22}(+off{1,23}/standby{1,24}),
  navAngle{1,17}, nav{1,1}/navReroute{1,2}/navOff{1,3}, roundabout{1,20}/roundaboutOled{1,34},
  turnByTurnIntro{1,32}, pointerWithIntro{1,33}, progress{1,5}. Byte layouts are in
  [`protocol/commands.md`](protocol/commands.md).
- **Map view:** MapKit showing the route polyline + live position (basic is fine).
- **Off-route:** point the rider back to the nearest route point ("return to route").
- A **GuidanceView** screen: pick GPX → start → the ring + map guide; stop → navOff. Lock new command
  bytes with `CommandsTests`.
- **DEFERRED (only this):** dynamic ONLINE rerouting (computing a brand-new route from a directions API
  when off-course) — needs a routing API + keys. GPX following + return-to-route IS in scope.
- **Ring guidance follows the official app (v2.8.0):** the ring is driven by a reverse engineered
  version of the official GPX navigation, spec in [`protocol/navigation.md`](protocol/navigation.md). It replaces the M3 pointer (an absolute bearing
  to the next route point every 1.5 s, which the ring drew as if the bike always faced north). Code:
  `SH2Protocol/Navigation/` (`NavStepFactory`, `NavBearing`, `NavGuidance`, `NavDirector`), fed by
  `GuidanceController` on every fix (`LocationTracker` without distance filter); `DeviceController.sendNav`
  sends in order, one at a time. The rider's direction comes only from GPS fixes (no compass); turns
  are the GPX's ≥ 46° bends; arrival is the official one (< ~50 m of the end, not early in a loop).
  The screen's own numbers (progress, next-turn banner, off-route) stay phone-side.

### M4 — Device, firmware & account
**Device settings** screen: getState{4,1}, versions (getVersions), serial (getSerial), localization{4,6},
compassCalibrate{4,3}, shutdown{4,4} (with confirm). **Firmware/DFU:** show nordic+STM versions and a
DFU section that is **clearly deferred** (stmDfu*/enterBootloader flashing is risky + needs the .dfu
packages — do NOT implement real flashing; show versions + an explainer). **Account/profile:** whoami,
log out, change server, forget device (wipe saved password), switch between server/BLE-only mode.
Consolidate `SettingsView`.

### M5 — Rides / Fitness + polish
**Rides:** detail view for a server ride, GPX export of a ride, history polish (`RidesView`).
**Fitness:** goals UI tied to the progress ring (progress{1,5}), fitnessIntro, distance/avg-speed
payloads. **Polish:** empty states, error handling, navigation consistency, the Settings/tabs layout.
**DEFERRED:** live GPS ride recording + upload (needs CoreLocation background + a recorder).

### M6 — Demo mode (simulated SH2)
A built-in **demo mode**: a fake connection to a fictitious SmartHalo so anyone can exercise **every**
feature with **no real hardware, no Bluetooth, and no recovery**. Great for screenshots, store-style
previews, trying the app before opening the ring, and UI development. Must coexist cleanly with the
real BLE path — the choice is made at *connect* time; the real flow is never affected.

- **`MockTransport` (app target, not `SH2Protocol`):** a class conforming to `SH2Protocol.Transport`
  (`enableNotifications` / `writeNoResponse` / `notificationStream`). It parses each outgoing bslink
  frame's `{service, cmd}` and feeds back a canned, well-formed reply on the DOWN channel so the real
  `Session`/`Frame`/`Crypto` layers run unchanged:
  - **Handshake:** reply to `getPeriphPubKey{0,1}` with `[RET_OK, pub(64), seed(4)]` using a fixed
    valid P-256 public key + seed so the ECDH→AES path actually runs (simplest: ship a known keypair so
    `deriveSecret` yields a cipher the mock also uses to decrypt/encrypt); `setCentralPubKey{0,2}` and
    `authenticate{0,3}` → `[RET_OK]`. (Acceptable alternative: a `Session`-level demo flag that
    short-circuits the handshake — but prefer running the real crypto so the mock also exercises it.)
  - **Control commands** (light/display/nav/sound/alarm/device writes) → `[RET_OK]`.
  - **Reads** return believable fake data: `getVersions` (e.g. fw 2.3.1 / bl 1.0.4), `getSerial`
    ("SH2-DEMO-0001"), `getState`, `alarmReport` (a plausible report blob). Keep values in one
    `DemoData` struct so they're easy to tweak.
  - **Unsolicited UP-channel:** optionally emit a fake alarm/report notification on a timer to show the
    notification path.
  - Honor the frame's `crypted` flag so replies decode correctly once the cipher is set.
- **Entry point:** a clearly-labelled **“Try the demo”** action in onboarding **and** on the scan
  screen. It builds a `DeviceController` whose `Session` wraps a `MockTransport` and (by default) jumps
  straight to `.ready` — skipping auth/recovery. A persistent **“DEMO — no real device”** banner/badge
  is shown throughout so it's never mistaken for a real connection. A `DiscoveredDevice`-like stand-in
  (or an `isDemo` flag on the controller) drives this; `DeviceController`/`BluetoothCentral.connect`
  gain a demo branch that returns the mock transport instead of a CoreBluetooth one.
- **Feature coverage (all must work in demo):** front light, display widgets + **carousel editor**,
  **GPX navigation with a SIMULATED GPS track** — load (or ship a bundled sample) GPX and advance a
  **fake location** along the route on a timer so the map animates and on-ring guidance fires without
  the user moving (inject a `CLLocation` source the guidance engine can be pointed at, instead of live
  CoreLocation); alarm/sound/touch; device settings (fake versions/serial/state); rides & fitness
  (canned sample data offline, or the real server if the user is logged in).
- **Recovery demo (optional but nice):** a toggle to start the mock in `.needsRecovery` so the user can
  watch `recover()` → `.needsReboot` → a simulated "reboot" (the mock flips an internal
  `rebooted`/empty-password state) → `reconnectAndFinish()` → `.ready`, demoing the whole recovery UX
  end-to-end without touching hardware.
- **Scope/placement:** `MockTransport`, `DemoData`, a simulated-location provider, and the demo
  wiring live in the **app target** (or a shared preview helper usable by SwiftUI previews + unit
  tests); `SH2Protocol` stays UI-free and transport-agnostic. No new BLE commands (reuse M1–M5), no
  external dependencies.

---

## v2.0 — UX redesign (M7–M12)

Source of truth for the look and the flows: **`docs/UX_DESIGN.md`** (wireframes, tokens, flows). All
features above already exist; these modules **re-house** them in a modern, map-first UI and add the few
missing pieces. Display name: **rehalo**. Copy in **EN + ES**. Always dark. v2.0.0 ships with M12.

MVP scope: GPX navigation + quick light/alarm. Ring customization, fitness, rides history, sound/touch
stay reachable as they were (themed only). Out of MVP: home-screen widget + Control Center control, live
ride recording, auto light/alarm automations.

### M7 — Foundation: iOS 17, theme, tab shell, connection chip
- `project.yml`: deployment target **16.0 → 17.0**. Background modes `bluetooth-central` + `location`.
- `UI/Theme/Theme.swift`: the color tokens of UX_DESIGN §6 (bg `#0B0D10`, surface, surface2, stroke,
  text, textDim, accent `#C6FF3D`, warn, danger, info), radii (card 20, button 14), metric font
  (`.rounded` + `monospacedDigit()`); `.preferredColorScheme(.dark)` app-wide.
- Reusable components: `StatusChip`, `ControlCard`, `PrimaryButton`, `MetricView`, `TurnBanner`,
  `RouteCard`, `EmptyState`.
- `RootView` → onboarding or a `TabView` **Map · Routes · Halo**. The old `ScanView`/`DeviceView`
  Form stops being the main path (keep `ScanView` only as the pairing step's source).
- **Auto-connect:** persist "my Halo" peripheral identifier; on launch `retrievePeripherals` +
  `connect`; auto-reconnect on drop. Global connection state drives the **chip**:
  connected / connecting / disconnected / needs re-pair (tap → Halo tab, retry, or recovery wizard).
- `Localizable.xcstrings` (EN + ES) for all new strings; units via `Measurement`/`MeasurementFormatter`
  with a **km/mi** setting (default from locale).
- Persistent DEMO badge when the controller is the mock.

### M8 — Map tab + Navigating screen
- SwiftUI `Map` (iOS 17) dark/muted, route `MapPolyline` in accent with outer glow, user position,
  recenter button. Bottom card: selected route (name · distance · ↗ gain · ETA) with **Change** and
  **▶ NAVIGATE**, or "Choose a route" → My routes / Use demo route. Hint when no Halo is connected
  ("No Halo: guidance will only show on the phone."); navigating without a Halo is allowed.
- **Navigating** (full screen): turn banner (icon + big distance + label; straight / left / right /
  slight / roundabout / arrival; amber "Back to the route · N m" when off-route), metrics panel
  (speed · remaining · % — first metric cycles speed/time/remaining gain, remembered), progress bar,
  light toggle, **STOP** with confirmation, end summary (distance, time, avg). Map orientation
  (v2.8.0, Map tab and Navigating): **North / Compass / Free** — the button toggles North ⇄ Compass
  (remembered per screen), turning or moving the map by hand sets it Free until Centre; Compass in
  Navigating is hybrid (GPS course moving, iPhone compass slow/stopped); the camera follows at
  display rate (`FollowCamera`).
- Reuse `GuidanceController` / `LocationTracker` / `GPXRoute` for all route math and ring commands; add
  only what the UI needs (next-turn type + distance, remaining distance). No phone-side off-route sound.
- Works in demo mode with the simulated location provider.
- **Implemented (v1.3.0):** `UI/Map/MapTab.swift`, `UI/Map/NavigatingView.swift` (+ summary),
  `UI/Map/RouteMapLayers.swift`; `Model/RouteSelection.swift` (selected-route hook:
  `select(_:subtitle:navigate:)`, `pendingNavigation`, `demoRoute(isDemo:)` → bundled `DemoRoute.gpx`
  or the built-in loop in demo); `Model/RouteManeuvers.swift` (turns/roundabouts derived from the GPX
  geometry, best-effort); `GPXRoute` gained `<ele>`, cumulative distance/climb, `length`, `totalGain`,
  `estimatedDuration`, `match(_:in:)`; `GuidanceController.shared` (app-wide, survives Halo drops,
  re-sends nav state on reconnect, background location while navigating) exposes `nextTurn`,
  `nextTurnDistance`, `remainingDistance`, `remainingGain`, `progress`, `speed`, `heading`, `elapsed`,
  `offRouteDistance`, `haloLost`, `summary` and `navState` (snapshot for the M12 Live Activity).
- **Destinations (v2.11.0):** the search pill searches saved routes + Apple places + recents
  (`UI/Map/SearchSheet.swift`, `Model/PlaceSearch.swift`); touch and hold the map drops a pin
  (reverse-geocoded). `Model/DestinationRouter.swift` routes with `MKDirections`, in the rider's route
  profile (M16) → NAVIGATE (turn by turn, street
  names on the ring), **Compass** (as the crow flies, `CompassDirector`), Save to my routes
  (`RouteSource.appleMaps`). NAVIGATE on a route > 500 m from its start asks: lead me to the start
  (Apple route chained before it) / start at the nearest point / go on my own. No rerouting. Details:
  `docs/protocol/navigation.md` §7.
- **Map redesign (v2.12.0):** no bottom card and no route restored at launch. The search pill becomes
  the route or destination, NAVIGATE floats, and a tap on the map hides every control including the
  tab bar (`UI/Map/MapContextBar.swift`, `MapViewMenu`). Search lists recent routes with ▶ plus My
  routes / Import GPX / demo.

### M9 — Routes library + GPX import
- Persist imported routes with **SwiftData**: name, source, distance, gain/loss, ETA, GPX file in
  Application Support, cached `MKMapSnapshotter` thumbnail, last used.
- **Routes** tab: cards (thumbnail, name, stats), search, swipe rename/share/delete, (+) sheet:
  Files / demo route. Segment "Rides" hidden until post-MVP.
- **Open-in:** `CFBundleDocumentTypes` + `UTImportedTypeDeclarations` for `com.topografix.gpx`,
  `.onOpenURL` → import → Route detail. Covers share sheet from Wikiloc / Komoot / Strava / Mail / Files / AirDrop.
- **Route detail:** map, stats grid, elevation profile (Swift Charts `AreaMark`, hidden without `ele`),
  share .gpx, **▶ NAVIGATE** (selects route, switches to Map, starts Navigating).
- Bundle a **short urban demo GPX** (~8–10 km, several turns + one roundabout); empty state offers it.
- **Implemented (v1.4.0):** `Model/SavedRoute.swift` (SwiftData `@Model`: id, name, `sourceRaw` →
  `RouteSource` Files/Shared/Included/Wikiloc/Komoot/Strava/Garmin/RWGPS sniffed from the GPX header,
  distance, gain, loss, ETA, createdAt, lastUsedAt, `lastActivity` sort key, fileName, contentHash,
  external-storage thumbnail); `Model/RouteLibrary.swift` (`RouteLibrary.shared`, `container`,
  `importGPX(from:defaultSource:)` — security-scoped + coordinated read, dedupe by SHA-256, Inbox
  cleanup — `addDemoRoute()`, `route(for:)` (stable `GPXRoute.id == SavedRoute.id`), `rename`,
  `delete` (removes file, clears selection), `markUsed`, `select(_:navigate:)`,
  `pendingDetail` (open-in → Routes › detail), `shareFile(for:)` → `GPXShareFile` Transferable
  exported as `<name>.gpx`, lazily cached dark `MKMapSnapshotter` thumbnails); `UTType.gpx`.
  UI: `UI/Routes/RoutesTab.swift` (list, search, inert "Rides · soon" segment, swipe/context
  rename/share/delete, (+) `ImportRouteSheet`, empty state), `RouteDetailView.swift`,
  `ElevationProfileView.swift` (Charts). Info.plist declares `com.topografix.gpx` (document type,
  role Viewer, rank Alternate; `LSSupportsOpeningDocumentsInPlace` = NO, the app copies the file).
  Map tab import / demo / NAVIGATE go through the library. `Resources/DemoRoute.gpx`: 8.3 km
  Eixample loop (Barcelona) — roundabout at Pl. Tetuan + 8 right-angle turns, ~60 m climb (demo
  data; name localized "Demo route · City centre"). Deferred: "Rides" segment (post-MVP), editing the
  geometry, iCloud sync of the library.

### M10 — Halo tab + Settings
- Header: name + connection state + battery %, **"Show battery on the ring"** → `showStateOfCharge{1,31}`.
- `ControlCard` **Light** (tap toggles; sheet for brightness + steady/blink) and **Alarm** (tap
  arm/disarm with haptic; shows armed-since; red "Motion!" state when triggered). Cards dimmed +
  "Reconnect" when not connected.
- Links: "Ring & widgets" → existing `DisplayView`/`FitnessView` (themed only, post-MVP badge), Settings.
- **Settings:** My Halo (rename, pair another, forget) · Alarm (sensitivity via `configureAlarm`,
  note that alerts need a live BLE link) · Account (existing `LoginView`/`AuthStore`) · General
  (units, language) · **Advanced** (firmware info, sync clock/language, calibrate compass, sound & touch
  = existing `SecurityView` parts, live log, demo mode, DFU explainer, shut down). Folds in the old
  `SettingsView` and `DeviceSettingsView`.
- **Alarm notification:** request notification permission; on an alarm report on the UP channel while
  connected → local notification "Your bike moved · HH:mm" that deep-links to the Halo tab.
- **Implemented (v1.5.0):** `UI/Halo/HaloTab.swift` — `NavigationStack(path: AppRouter.haloPath)`
  with value routes `HaloRoute` (settings, advanced, rename, pair, recovery, ringWidgets, display,
  fitness, soundTouch, liveLog, login, rides); root = `HaloHomeView` (header ring + name + state,
  "Show battery on the ring" → `showCharge()`, Light / Alarm `ControlCard`s, `LightSheet`, links) ·
  `HaloOfflineView` (saved Halo not reachable) · `ScanView` (nothing paired; now themed, no own stack,
  `onPaired:`). `AppRouter.showSettings` sheet is gone → `openSettings()`, `showHaloHome()`,
  `openRecovery()`. `UI/Halo/HaloRecoveryView.swift` = the old in-form recovery (reached from
  "Re-pair" and the chip; **M11 swaps it for the wizard**). `UI/Settings/SettingsView.swift`
  (My Halo · Alarm · Account · General · About, + `RenameHaloView`) and `AdvancedSettingsView.swift`
  (firmware/serial/state/alarm report, sync clock, compass, Sound & touch → `UI/SoundTouchView.swift`,
  live log, demo toggle + **Simulate alarm**, device password, DFU explainer, disconnect, shut down).
  Deleted `DeviceView`, `DeviceSettingsView`, `SecurityView`, old `SettingsView`.
  **Alarm monitoring:** `SH2Protocol/Notifications.swift` adds `AlarmReport(reply:)` (`[OK, armed,
  triggerCount, vigilant, …]`) and `UpNotification` (UP-channel
  types 0 touch · 2 movement · 3 light · 4 info · 5 carousel · 0xF8 log), tested in `NotificationsTests`. `DeviceController` installs a UP
  handler on ready: movement `[2,1]` while armed → re-read `alarmReport`; trigger counter above the
  baseline taken at arming (or no parseable report) → `alarmTriggeredAt` + `AlarmNotifier.postAlarm`
  (throttled 1/min). A 15 s foreground poll while armed is the backstop. Also new:
  `alarmArmedSince` (persisted per ring), `lastAlarmReport`, light state from UP type 3,
  `setAlarm`/`renameDevice` return Bool, `simulateAlarm()` (demo). `MockTransport` keeps alarm state
  and `simulateAlarm()` pushes a real UP frame. `Model/AlarmNotifier.swift`: UNUserNotificationCenter
  delegate (set in `SmartHalo2App.init`), `requestAuthorization()` (asked on first arm, in
  Settings › Alarm, and M11 onboarding should call it), banner in foreground, tap →
  `AppRouter.showHaloHome()`. `AppSettings.alarmVigilant` (Vigilant or Lenient, the `vigilant` byte of
  `configureAlarm`).
  Deferred: Time Sensitive / Critical alerts (need entitlements), alarm alerts without a live BLE
  link (impossible), "Keep screen on while navigating" toggle (optional in §4.6; not needed yet).

### M11 — Onboarding v2 + recovery wizard
- Onboarding: 1 Welcome → 2 Pair (auto-scan, single device highlighted, "Try without a Halo" = demo) →
  3 Permissions (location, notifications, each explained before the system prompt) → 4 Account
  (optional; "Connect server" and "Not now" same weight). Saves "my Halo".
- **Recovery wizard** (modal, opened when the handshake reports `.needsRecovery` — from pairing or the
  chip): step 1 explain → `recover()`; step 2 reboot instructions, auto-advance when the device
  reappears (manual "I've rebooted it" fallback) → `reconnectAndFinish()`; step 3 done. The new
  password is not shown (reachable in Advanced). `.needsRecovery` only follows a `RET_FAIL` to every
  stored password and the empty one; an un-paired ring gets the saved password back without the
  wizard, and a recovery reuses it (`docs/protocol/pairing.md`, "When a ring stops taking a password").
- **Implemented (v1.6.0):** `UI/Onboarding/OnboardingView.swift` (replaces the old server/BLE
  choice screen) — Welcome (turning accent ring, static with Reduce Motion) → Pair (auto-scan on
  appear, radar pulses, "Found" list, a lone Halo highlighted, RSSI hint, tap → `pair(with:)` with
  "Connecting and verifying…"; "Try without a Halo (demo mode)" → `startDemo()`; "Not now" skips) →
  Permissions (Location via a `LocationTracker` When-In-Use prompt, Notifications via
  `AlarmNotifier.requestAuthorization()`; rows show Allow / Allowed / Settings when denied) →
  Account (optional: "Connect server" → `LoginView` sheet, "Not now" same weight) →
  `completeOnboarding` → Map tab. 3-segment progress bar on steps 2–4.
  `UI/Recovery/RecoveryWizard.swift`: full-screen modal hosted by `RootView`
  (`.fullScreenCover(isPresented: AppRouter.showRecovery)`); `AppRouter.openRecovery()` now just
  presents it (chip, Halo tab "Re-pair", Advanced, pairing). `HaloConnection.pairingNeedsRecovery`
  (Combine subject) fires when a `pair(with:)` handshake ends in `.needsRecovery` → `RootView`
  opens the wizard; the onboarding's pair step advances to Permissions as soon as the state turns
  `.connected` (directly or after the wizard). Steps: 1 explain → `recover()` (progress, error →
  "Try again" = `reconnectAndFinish()`), 2 reboot (`UsbRebootIllustration` loops a micro-USB cable
  plugging into the ring's bottom; options micro-USB / battery / drain / UART) with
  `RebootWatcher` — releases the link, scans in 5 s windows and, once the ring has been missing
  for a whole window and is seen again, calls `reconnectAndFinish()` itself; "I've
  rebooted it" is the manual fallback; a ring that never disappears never auto-triggers — and 3
  done. The password is no longer shown on the Halo tab (`NewPasswordCard` removed); Advanced ›
  Device password keeps it. **Demo:** `DeviceController.simulateNeedsRecovery()` + demo branches
  of `recover()` / `reconnectAndFinish()` play the same phase sequence without Bluetooth (the mock
  has no ECDH); Advanced › Demo › **Simulate re-pair** opens the wizard, the simulated reboot is
  detected after ~7 s. Removed: `HaloRecoveryView`, `HaloRoute.recovery`. Deferred: requesting
  *Always* location (asked at first background navigation per §4.1, iOS escalates When-In-Use on
  its own); a proper reboot illustration (SF Symbol for now); auto-advance relies on the ring
  advertising after boot — unverified on hardware.

### M12 — Live Activity / Dynamic Island + release polish
- New **Widget Extension** target in `project.yml` (ActivityKit only — no home-screen widget in MVP),
  `NSSupportsLiveActivities`. Shared `ActivityAttributes` (route name, Halo connected) + content state
  (turn type, turn distance, speed, remaining, %).
- Compact (turn icon + distance · %), minimal (icon), expanded and lock screen (UX_DESIGN §4.8). Start
  on Navigating, update on turn change / every ~50 m and ≥10 s, end with a short summary.
- Light button = `LiveActivityIntent` (runs in the app process, uses the open BLE session).
- Polish pass: VoiceOver labels on metrics, Dynamic Type, Reduce Motion, empty/error states, demo
  coverage of every new screen. Version **2.0.0**.
- **Implemented (v2.0.0, build 18):** new XcodeGen target **`HaloLiveActivity`** (`app-extension`,
  WidgetKit, iOS 17, bundle id `com.sh2.smarthalo2.LiveActivity`, embedded in `PlugIns/`; CI checks
  the `.appex` and `NSSupportsLiveActivities` in the unsigned archive). `Sources/Shared/` is compiled
  into both targets: `HaloNavAttributes` (`routeName`; `ContentState` = turn raw value, SF symbol,
  turn distance text, instruction, speed value/unit, distance value/unit — remaining while riding,
  ridden once ended —, progress, offRoute, haloConnected, lightOn, ended) and
  `ToggleHaloLightIntent` (`LiveActivityIntent`, not discoverable; `perform()` only acts in the app
  build via the `HALO_APP` compilation condition → `LiveActivityManager.toggleLightFromIntent()` →
  `DeviceController.setLight`). `Sources/HaloLiveActivity/HaloLiveActivity.swift`: compact leading
  (icon + distance, accent / warn off-route) · trailing (%) · minimal (icon) · expanded (icon, big
  distance + instruction, light button, speed · remaining · %, progress bar) · Lock Screen ("Halo ·
  route" + Halo state, turn row + light button, 3 metrics, progress bar); own EN/ES
  `Localizable.xcstrings`. `Model/LiveActivityManager.swift` (activated in `SmartHalo2App.init`)
  observes `GuidanceController.shared` + connection + light: starts with guidance, pushes at once on
  turn / off-route / Halo / light changes, else every ≥ 50 m AND ≥ 10 s; ends on stop/arrival with a
  final state (average speed, distance ridden, %) dismissed after 4 min; ends leftovers from a
  previous process on launch. `TurnKind.instructionText` (plain localized string).
  **Polish:** `CFBundleDisplayName` = **rehalo** (so "Share › rehalo");
  *Always* location requested once (`LocationTracker.requestAlwaysOnce`) when the app becomes active
  again after the first real (non-demo) navigation that went to the background
  (`NSLocationAlwaysAndWhenInUseUsageDescription` added; When-In-Use keeps working regardless);
  `RouteLibrary` snapshot uses the iOS 17 `UITraitCollection { }` mutations API (deprecation gone);
  Map tab camera moves honour Reduce Motion; 23 stale String Catalog keys removed (left by the
  deleted Device/Recovery/old Settings views), new strings EN+ES. VoiceOver labels / values on the
  metrics, icon-only buttons and the Live Activity's light button + progress. Deferred:
  home-screen widget and Control Center control (post-MVP, BLE-from-extension spike); push-token
  updates (not needed — the app runs in the background while navigating); localized
  `InfoPlist.strings` for the permission prompts (English only).

### M13 — Incoming-call alerts on the ring (v2.13.0)

Based on the official app's call alert, adapted to what iOS allows.

**Detection.** `CallAlertController` observes `CXCallObserver`: a call is ringing if it is incoming,
not connected and not ended. It needs no entitlement, so it should work with free signing. It gives no caller name or number, and it does not wake a suspended app. VoIP apps
that report through CallKit should appear too.

| App state | Behaviour |
|---|---|
| In use, navigating, or on a ride | Immediate: the app keeps running |
| Suspended, ring connected | On the ring's next UP event (`handleUp`, about every 60 s). Real delay to be measured |
| Closed by hand | No alert |
| Ring connects during the call | Alert sent on connection |

**On the ring.** The firmware has no ANCS client (`BLE_ANCS_C_ENABLED 0`, no bonding), so the app sends:

| Moment | Commands |
|---|---|
| Ringing | `{1,7}` type 0, HSV `143,219,198`, repeat 60, text "Incoming call" (localized); `{2,0}` `callTrack`, volume 50, repeat 18 |
| Answered, ended or missed; alerts turned off | `{1,8}`, then `{2,1}` |
| Short tap (`"s"`) during the alert, or sound turned off | `{2,1}` only; the ring keeps pulsing |

- **Duration:** about 30 s, not the official repeat of 255. That value overflows the firmware's
  `uint16_t` duration and would hold the ring's turn guidance for about 125 s if `{1,8}` never arrived.
  With repeat 60, a suspended app holds it for about 61 s at most.
- **Guidance:** the firmware skips turn output while a notification is active (`RideTask.c:1306`). The
  iPhone keeps guiding; the ring resumes after `{1,8}`.
- **Queue:** alerts go through `sendNav`, because `run` drops commands while another is in flight.
- **Answering or declining:** not possible from the ring, as in the official app.
- **Text:** caps at 29 characters + NUL through `navText` (`RideTask.c:769` copies without a bound).

**Settings (Settings › Call alerts):** Show calls on the Halo (on), Call alert sound (on), Test alert (6 s, no call needed).

**To check with the ring:**
1. Whether the OLED image stays after `{1,8}`, which doesn't clear it. If it does, add `{1,3}` only when
   not navigating (`silenceNavigation` clears it).
2. That the guidance returns after a call while navigating with the screen locked.
3. The real delay with the app suspended.

**Not included:** SMS and other app notifications (next step to try: an App Intent run from a Shortcuts
automation, for Messages and Mail only; WhatsApp and similar would need ANCS).

### M14 — Rain alerts on the ring (v2.14.0)

Promised on Kickstarter and never shipped; the firmware has the storm icon (`{1,7}` type 32), which no
official app code sends.

**Source.** Open-Meteo `v1/forecast` with `minutely_15=precipitation`, `forecast_minutely_15=6`,
`timeformat=unixtime`: free, no key, no entitlement. WeatherKit needs a paid developer membership. Fine
for non-commercial use, with attribution (shown in Settings › Rain alert).

**When it runs.** Only with Rain alert on (default **off**), a ring connected and a ride in progress
(`GuidanceController.following` or `RideMetrics.isRunning`). The app is running then and has a position,
so this needs no extra background work. `RainAlertController` checks every 60 s and fetches every 10 min.

**Rule** (`RainForecast`, `RainWatch` in `SH2Protocol`, unit-tested):
- Rain = at least 0.2 mm in a 15-minute slot, starting within 30 minutes. Past slots don't count.
- One alert per spell. Another needs a dry forecast at least 30 minutes after the last alert.
- No alert during a call alert, or within 150 m of a turn while navigating: it waits for the next check.

**On the ring.** `{1,7}` type 32, HSV `170,220,255` (blue, unlike a call), repeat 10 (about 6 s), text
"Rain in 20 min" / "Rain now" (localized); `{2,0}` `NavSound.info` at volume 50; `{1,8}` after 6 s, or the firmware
would keep the turn guidance off for about 11 s.

**Privacy.** The position is rounded to two decimals (about 1 km) and sent every 10 minutes while riding.

**To check:** the reply's slot times are taken as the END of each slot; if that's wrong, alerts arrive 15
minutes off. Where 15-minute data isn't available, Open-Meteo may interpolate hourly data, so accuracy
varies by region. Both need a real rainy ride; so does the storm icon's look on the OLED.

### M15 — The screen says what the ring says, and ride recording (v2.15.0)

The Navigating screen used to run its own turn detection and off-route logic next to the ring's, so they
disagreed. Now both read `NavGuidance`, as in the official app (`docs/protocol/navigation.md` §8).

**Screen.** `RideEngine` (`SH2Nav`) feeds it: next turn, its distance (the ring's number, 25 m short of the
manoeuvre), off-route state and pointer. Its own tracking stays only for progress, distance left and speed.
The banner shows the street of a routed destination, and off-route an arrow aimed like the ring's pointer;
before reaching the route it reads "To the route's start".

**Ride recording.** Settings › Advanced › Record rides (default **off**): one `RideTrace` per ride in
Documents/rides, the latest 10, with every fix, what the screen showed and what the ring was told. "Share the
last ride" exports it to study a ride afterwards. It includes the route, so it never leaves the phone alone.

### M16 — Route profiles and Apple's steps (v2.16.0)

MapKit has one bike profile and no notion of rider: `MKDirections.Request` offers `transportType`,
`requestsAlternateRoutes`, `highwayPreference` and `tollPreference`, nothing else (checked up to the iOS 27.2 SDK).
"Avoid hills" and "avoid busy roads" exist in the Maps app, not in the API. So a profile asks MapKit for the closest
thing it has.

**Route profiles.** `RouteProfile` in `Model/DestinationRouter.swift`. The rider picks one on the map, under the
pill; it's remembered (`AppSettings.routeProfile`, `sh2.route.profile`, default City). It also applies to "lead me
to the start".

| Profile | Request | When Apple has no route |
| --- | --- | --- |
| City | `.cycling` | Walking route, as before |
| Road | `.automobile`, `highwayPreference` and `tollPreference` `.avoid` | "No route found" |
| Trails | `.walking` | "No route found" |

Road is a car route, not a bike route. `.avoid` is a preference, so it can still use motorways, and it may pick fast,
busy roads or tunnels closed to bikes. Options with `hasHighways` are dropped when another option has none, and the
rider always sees a warning. Its time is `GPXRoute.estimatedDuration`, not the car's.

`.cycling` has no iOS check any more: the SDK header marks it iOS 14+, Apple announced it in 2025, and a failure on
an older iOS already falls back to the walking route. It stays inside `#if compiler(>=6.2)`, for Xcode 16 builds.
What the UI calls bike, car or foot comes from `MKRoute.transportType`, not from what was asked.

**Alternatives.** `requestsAlternateRoutes = true`, up to 3 options. Apple only returns them when it has them. With
more than one, chips under the profiles show distance and time; the others are drawn dimmed under the chosen one.

**Notices.** `advisoryNotices` and `step.notice` go to the rider before leaving, through `MapNotice`, plus a line
when part of the route is on foot. A step with a notice, or on foot in a route that isn't, is a caution step
(`NavStep.mode = 1`): the ring shows it in its caution colour, like the official app's caution stretches.

**Apple's steps as turns.** The official app rode destinations on typed Valhalla steps, not on its GPX detector.
`RoutedSteps.swift` (`SH2Nav`) does the same with `MKRoute.steps`, and `NavSteps.swift`, the GPX flow, doesn't change:

- MapKit gives no manoeuvre type, only geometry and text. The angle comes from the geometry, with headings read 20–40 m
  either side of the manoeuvre, so a rounded corner gives its whole angle.
- Under 20° a change of step is a new street name, not a turn: it merges into the previous stretch, unless the
  caution state changes or it's a roundabout.
- Apple doesn't document which end of a step's polyline its instruction belongs to. It's read from the route: a last
  step of 1 m or more means the end, a shorter one means the start. This only decides which text goes with which turn.
- Roundabouts are found in the text ("roundabout", "rotonda", "glorieta"). The ring shows a normal arc with the net
  angle, read where the path stops turning, as how far round it goes depends on the roundabout's size and the exit.
  The OLED shows `Salida 2 · Carrer X` / `Exit 2 · Carrer X`.
- Steps that don't add up to the route within 10 % are ignored, and the turn detector takes over.
- A recorded ride keeps the raw steps (`RideTrace.Header.routedSteps`), absent on GPX rides.

The lead-in of "lead me to the start" stays on the detector, chained in one path with the GPX.

**Not done:** rerouting off-route (`navReroute` is still unsent), elevation of Apple routes (`MKRoute` has none, so
"Climb left" stays empty on them), the ring's native roundabout commands (MapKit doesn't give the exits' angles),
a real road-bike profile (needs another router, e.g. Valhalla's `bicycle_type`).

**Not verified on a phone:** whether Apple returns alternatives by bike, how good Road is, whether `.cycling` works
on iOS 17–25, which end Apple's instructions belong to, and whether `hasHighways` covers Spanish autovías.

### M17 — Time-based guidance, BRouter, MapLibre and offline maps

Four pieces, each usable without the next: the ring's guidance announces turns by time; routes can come
from a BRouter server of the rider's; a second map engine, MapLibre, with free layers; and offline areas
for it. Apple Maps stays the default map engine until MapLibre has been tried on a phone.

**Guidance (`SH2Nav`, `TurnTiming`).** The arc used to run from 95 m to 20 m whatever the speed. Now
every notice is `seconds × max(speed, 1 m/s) + 7 m`, the speed from `CLLocation.speed`:

| Phase | Seconds to the manoeuvre | Ring |
| --- | --- | --- |
| Far | > 60 | nothing |
| Upcoming | 60–30 | the next turn is known, no arc |
| Prepare | 30–14 | the arc appears and fills |
| Approach | 14–10 | still filling |
| Order | ≤ 10 | full arc, turn sound |

- Two manoeuvres under `32 × speed` metres apart are chained: the second arc rides behind the first.
- An arc never empties because the rider slowed down (`heldProgress`).
- Fixes worse than 40 m don't guide. `GPSQuality`: weak after 30 s without a good fix, lost after 60 s
  (a pill on the Navigating screen; the clock keeps it moving when no fix comes at all).
- Off route (matched engine, `RouteMatcher`): further than 60 m + accuracy for 4 s, or further than 50 m
  + accuracy riding more than 60° off the route's direction on 2 fixes in a row. Back on it after 10 s
  within 20 m + accuracy; the first join of a ride takes 3 s. The wrong-way detector, the arc back onto
  the route and the orange pointer stay as they were.
- Arrival: within 40 m of the end with more than 10 % of the route ridden (half of a loop). The
  destination's ring fills from 160 m.
- Typed manoeuvres: `RoutedStep.maneuver` (`RoutedManeuver`: straight, slight / normal / sharp turns,
  keep left / right, U-turn, roundabout with exit and direction). A roundabout with a known exit is a
  ROUNDABOUT step: the ring gets `roundabout {1,20}` with the exits' angles (`RoundaboutExits`: the one
  to take first, the others spread from the entry) and `roundaboutOled {1,34}`; Apple's text ("take the
  second exit") still gives the exit, so Apple routes get the glyph too. The classic engine keeps the
  official off-route rules; it shares the timing and the arrival rule.

**Routing (`RouteProvider`).** `BRouterRouteProvider` calls `<base>/brouter?lonlats=…&profile=…
&alternativeidx=…&format=geojson&timode=2` (`BRouterRequest`), the base URL from Settings › Advanced ›
BRouter server (BRouter itself, `http://localhost:17777`, or a proxy such as sh2-server's
`https://server.example.org/routing/brouter`; the base's own path is kept). When the base is the rider's
own sh2-server and they are logged in, the request carries `Authorization: Bearer <access token>`,
refreshed once on a 401. `BRouterRoute` reads the GeoJSON: coordinates with elevation, `voicehints`
`[index, command, exit, distance, angle]` into typed steps. Profiles: City `trekking`, Road `fastbike`,
Gravel `gravel`, MTB `mtb`; stops are more `lon,lat` pairs (Apple: leg by leg). `AppleRouteProvider`
wraps `MKDirections`: City and Gravel ask for bike routes (no silent fall to a walking route any more:
the error shows), Road for car routes without motorways, MTB for walking routes, and the rider is told
("Calculated with Apple Maps: no gravel profile, using City."). `RoutingService` picks BRouter when set
and answering, else Apple with a notice saying why. Off the route with BRouter set, `GuidanceController`
asks for a leg from the rider to the route 300 m ahead of where they left it and the ride carries on
along it (`RideEngine.rerouted`: the leg's typed steps plus what is left of the route's); a failed
request waits 30 s, doubling to 8 min (`RerouteBackoff`). A saved destination keeps its elevation
(`<ele>` in the GPX) and its typed steps (`<uuid>.steps.json` next to it), so riding it again has the
same manoeuvres.

**Map engine (Settings › Advanced › Map engine: Apple Maps / MapLibre (beta)).** `HaloMapView`
(`UIViewRepresentable` over `MLNMapView`, MapLibre Native iOS 7.0.0 by SPM) serves the Map tab,
Navigating and the route detail when chosen; the 3D route view stays on MapKit (MapLibre Native has no
3D terrain). Base styles from OpenFreeMap: Night (`dark`) and Day (`liberty`). Layers, in a sheet:
Topo IGN (WMTS MTN) and Satellite (WMTS PNOA), CC BY 4.0, under the labels; shaded relief from
Mapterhorn's Terrarium tiles (`MLNRasterDEMSource` + `MLNHillshadeStyleLayer`); CyclOSM's lite overlay,
online only; the downloaded areas' outlines. The route is one GeoJSON source with the halo, the lime
line and direction arrows along it; start, finish, stops and the destination are a symbol layer. The
Navigating camera is `FollowCamera`'s, applied to `MLNMapView` at display rate, the rider an annotation
view hosting `RiderMarker`. Attribution: MapLibre's (i) button plus `MapAttributionBar` on the map.
Thumbnails: `MLNMapSnapshotter` (`MapLibreSnapshot`) when MapLibre is the engine.

**Offline (`OfflineMapStore`, Settings › Advanced › Offline maps).** Saving a route downloads a 1 km
corridor round it (a chain of squares every 500 m) at zoom 1–14 as an `MLNShapeOfflineRegion`, plus a
world pack (zoom 0–1) per style for the style, glyphs and sprites. OpenFreeMap's terms (3,000 tiles or
50 MB per download, 4 connections) are kept: a corridor over the tile estimate isn't downloaded, a
download over the bytes is stopped, `MapLibreSetup` caps the connections. Settings: Wi-Fi only (default
on), Save the map with each route (default on). The screen lists the areas with size and state, swipe
to delete or update. The raster layers aren't part of the packs (they're added at run time).

**Not done:** PMTiles regions from a URL of the rider's (large areas), raster layers offline, a pixel
ratio setting (iOS packs download at the device's scale), stops in the UI (the providers take them),
elevation for Apple routes.

**Not verified on a phone:** everything MapLibre draws (the style URLs, the WMTS templates, the
hillshade look, the annotation's rotation at 60 fps), the roundabout glyph's direction on the ring
(counter-clockwise for right-hand traffic is the assumption), and BRouter's `timode=2` voice hints
against a real server.

**Post-MVP backlog (from UX_DESIGN §9):** home widget + Control Center control (needs a BLE-from-intent
spike), live ride recording + "Rides" history, fitness goals, Strava, optional automations.

### Deferred across the board
Real **OTA/DFU flashing**, **iOS→ring forwarding of app notifications** (iOS has no
NotificationListener equivalent and the firmware has no ANCS client; calls are covered by M13), **live
GPS ride recording**, **Strava linking** (needs OAuth + Strava app keys). These need external APIs,
entitlements, or large UIs.
