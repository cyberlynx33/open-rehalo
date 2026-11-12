# rehalo — iOS app UI/UX design

App display name: **rehalo**. This is the design reference for the app; the implementation modules are
in `docs/APP_SPEC.md`.

Product references: **Wikiloc**, **Komoot**, **Strava**, **Apple Maps**, **Apple Home**.

---

## 1. Vision and principles

> You open the app, the Halo is already connected, you pick a route and ride. Everything else is one
> tap away or tucked out of sight.

1. **Map first.** The app is mostly used for riding and following GPX routes, so the home screen is
   the map.
2. **One tap for frequent actions.** Light, alarm and "▶ Navigate" are never more than one tap away
   from the screen where they're used.
3. **Readable on the handlebars.** Large metrics, high contrast, touch targets of 56 pt or more in
   ride mode, and usable with gloves.
4. **You always know if there's a Halo.** A global connection chip appears on every tab.
5. **Technical things stay hidden.** The log, firmware, shutdown and recovery don't appear in daily
   use. Recovery only shows up as a wizard when needed.
6. **No mandatory account.** It works over BLE alone. Your own server is optional.
7. **Can be tried without hardware.** Every screen works in demo mode.

---

## 2. Feature inventory → destination

| Area | Feature | Destination | Release |
|---|---|---|---|
| Connection | BLE scan, connection and handshake | Onboarding (pairing) + auto-connect + chip | **MVP** |
| Connection | Recover / re-pair | Recovery wizard (modal) | **MVP** |
| Connection | Demo mode | Onboarding + Settings › Advanced | **MVP** |
| Onboarding | Server login / BLE only | Onboarding step 4 (optional) + Settings › Account | **MVP** |
| Navigation | GPX import, map, ring guidance, return to route | **Map** + **Routes** tabs | **MVP** |
| Light | On/off, brightness, blink | Light card (Halo) + button in Navigating and in the Live Activity | **MVP** |
| Light | Home widget + Control Center | Widget / Control | Post-MVP (needs a spike) |
| Alarm | Arm/disarm, report | Alarm card (Halo) + local notification | **MVP** |
| Alarm | Sensitivity / config | Settings › Alarm | **MVP** |
| Device | Rename | Settings › My Halo | **MVP** |
| Device | FW, serial, state, clock sync, compass, shutdown, forget password, DFU | Settings › Advanced | **MVP** |
| Debug | Live log | Settings › Advanced | **MVP** |
| Ring | Widgets, carousel, intros | Halo › Ring | Post-MVP (accessible as is) |
| Fitness | Goal + progress ring | Halo › Ring › Goal | Post-MVP (accessible as is) |
| Sound/touch | Play/stop, touch sounds | Settings › Sound & touch | Post-MVP (accessible as is) |
| History | Server rides, detail, export | Routes › "Rides" segment | Post-MVP |
| — | **GPS ride recording** (new) | Map › ● Record | Post-MVP |

"Accessible as is" means the existing screen is linked from its new place with the dark theme applied,
but isn't redesigned in the MVP.

---

## 3. Navigation architecture

```
App
├─ Onboarding (first use only; full screen)
│   1 Welcome → 2 Pair Halo (or Demo) → 3 Permissions → 4 Account (optional)
│
└─ TabView ──────────────────────────────────────────────
   ├─ 🗺  Map             (home)
   │    ├─ [sheet] Choose route  → compact Routes list
   │    └─ [fullScreen] Navigating
   │
   ├─ 📍 Routes
   │    ├─ (+) Import  → Files
   │    └─ [push] Route detail → ▶ Navigate (jumps to Map/Navigating)
   │
   └─ ⭕ Halo
        ├─ Cards: Light · Alarm
        ├─ [push] Ring (post-MVP: DisplayView / FitnessView)
        └─ [push] Settings
             ├─ My Halo (name, forget, pair another)
             ├─ Alarm (sensitivity)
             ├─ Account (optional server)
             ├─ General (units, language)
             └─ Advanced (log, firmware, compass, clock sync, shut down, demo)

Global:
  • Connection chip (top right on every tab)
  • [modal] Recovery wizard (when the Halo asks to re-pair)
  • Persistent "DEMO" banner in demo mode
  • External entry: "Open with rehalo" (.gpx) → Routes › Detail of the imported route
```

**Connection chip.** It has four states:

| State | Look | Tap |
|---|---|---|
| Connected | `● Halo` in neon green | Opens the Halo tab |
| Connecting / reconnecting | `◌ Connecting…` in amber, pulsing | Opens the Halo tab |
| Disconnected | `○ No Halo` in gray | Retries / opens pairing |
| Needs recovery | `⚠ Re-pair` in amber | Opens the recovery wizard |

---

## 4. MVP screens

### 4.1 Onboarding (first use)

```
┌──────────────────────┐ ┌──────────────────────┐ ┌──────────────────────┐ ┌──────────────────────┐
│                      │ │ Pair your Halo       │ │ Permissions          │ │ Sync your rides?     │
│      ◯ (animated      │ │                      │ │                      │ │                      │
│       ring)          │ │   ◉ searching…       │ │ 📍 Location           │ │ Connect your own     │
│                      │ │                      │ │   to guide you       │ │ SmartHalo server to  │
│  Your SmartHalo,     │ │  ┌────────────────┐  │ │   [Allow]            │ │ save your rides.     │
│  alive again.        │ │  │ ⭕ SmartHalo-3F2 │  │ │                      │ │                      │
│                      │ │  │    -58 dBm   ▸ │  │ │ 🔔 Notifications      │ │ [Connect server]     │
│                      │ │  └────────────────┘  │ │   if the alarm fires │ │                      │
│                      │ │                      │ │   [Allow]            │ │ Not now              │
│  [   Get started   ] │ │ ✨ Try without a Halo │ │                      │ │                      │
│                      │ │                      │ │  [  Continue  ]      │ │                      │
└──────────────────────┘ └──────────────────────┘ └──────────────────────┘ └──────────────────────┘
```

- **Step 2:** the scan starts on its own. If there's only one Halo, it's highlighted and a single tap
  is enough. After the handshake, if the Halo asks for recovery, the wizard opens directly (§4.7).
  "Try without a Halo" enters demo mode and skips the pairing steps.
- **Step 3:** each permission is explained before the system dialog appears. "Location" first asks
  for *When In Use*; *Always* is requested the first time navigation runs in the background.
- **Step 4:** the account is optional and visible, but "Not now" has the same weight as the main
  button.
- The paired Halo is saved as **"my Halo"**, and from then on the app auto-connects (§5.3).

### 4.2 Map (home, not navigating)


```
┌──────────────────────────┐
│ ╭ Montseny Loop        ✕╮ ◉ │ ← the route or destination; otherwise the search
│ ╰ 42.3 km · ↗ 860 m ·…  ╯   │
│        (dark map)        │
│      ╭──╮                │
│   ╭──╯  ╰─╮  ← selected  │
│   │   ◉   │    route
│   ╰───────╯           ▤  │ ← map view
│                       ⌖  │ ← center
│            [ ▶ NAVIGATE ]│ ← floating
├╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
│  🗺 Map   📍 Routes   ⭕ Halo │ ← translucent
└──────────────────────────┘
```

- Dark map style (`.mapStyle(.standard(emphasis: .muted))` with `preferredColorScheme(.dark)`). The
  route is drawn in neon with an outer glow for contrast.
- **On open:** map at the user's position, no route. There's no bottom card.
- **A tap on the map** hides the whole interface, tab bar included; another tap brings it back. With
  a route or destination, a minimal chip stays at the top.
- **To reach a route:** the search shows recent routes with a direct ▶, recent destinations and
  `[My routes]`, `[Import GPX]` and "Use demo route".
- `▶ NAVIGATE` is the main CTA: a floating neon button with black text.
- With no Halo connected, you can still navigate (on the phone only). On choosing a route or
  destination, the notice "No Halo: guidance will only show on the phone." appears for 4 s.

### 4.3 Navigating (full screen)

```
┌──────────────────────────┐
│ ┌──────────────────────┐ │
│ │  ↰   350 m           │ │ ← next turn (icon + distance, 48–64 pt)
│ │      turn left       │ │
│ └──────────────────────┘ │
│                          │
│        (map in follow    │
│         mode,            │
│         heading-up)      │
│            ▲ you         │
│                          │
├──────────────────────────┤
│  24.5      18.1    43%   │ ← large metrics (SF Rounded)
│  km/h      km left done  │
│  ━━━━━━━━━━━━░░░░░░░░░░  │ ← route progress bar
│ [💡]   [ ■ STOP ]    [⋯] │
└──────────────────────────┘
```

- **Orientation:** heading-up by default (the map turns with the rider); a tap on 🧭 switches to
  north-up and the choice is remembered.
- **Nothing automatic:** starting or stopping navigation doesn't touch the light or the alarm.
- **Turn panel:** SF Symbol icon (`arrow.turn.up.left`, `arrow.uturn.*`,
  `arrow.triangle.turn.up.right.circle` for roundabouts) + distance. With no turn nearby, it shows
  "Continue straight · 2.4 km".
- **Metrics:** speed, remaining distance and % completed. `⋯` swaps a metric for time, altitude or
  remaining climb. The choice is saved.
- **Off route:** the turn panel turns amber and says `⟲ Back to the route · 120 m`, with an arrow
  towards the nearest point. The ring shows the return-to-route pointer (current `GuidanceController`
  behavior). The phone adds no sound.
- **Wrong way** ([`MAP_MATCHING_SPEC.md`](MAP_MATCHING_SPEC.md) §9, matched engine): an amber banner, "Wrong
  way", with **Invert route** (GPX rides) and **Ignore**, and a warning haptic. The ring shows its U-turn
  glyph.
- **[💡]** toggles the front light without leaving the screen.
- **STOP** asks for confirmation with a long press or a dialog, to avoid stopping by accident. On
  stopping, `navOff` is sent and a brief summary appears (distance, time, average).
- **Arrival:** a finish animation on the phone and the intro or 100 % progress on the ring.
- The **Live Activity** starts with navigation (§4.8).

### 4.4 Routes (library)

```
┌──────────────────────────┐
│ Routes                (+)│
│ [ Routes ] [ Rides ]     │ ← "Rides" is post-MVP and hidden until then
│ 🔍 Search                 │
│ ┌──────────────────────┐ │
│ │ ▒▒mini-map▒▒  Montseny│ │
│ │ ▒▒  ~╮  ▒▒   Loop     │ │
│ │ ▒▒▒▒▒▒▒▒▒▒   42 km ↗860│ │
│ └──────────────────────┘ │
│ ┌──────────────────────┐ │
│ │ ▒▒▒▒▒▒▒▒▒▒   BCN bike │ │
│ │ ▒▒  ─╯  ▒▒   lane     │ │
│ │ ▒▒▒▒▒▒▒▒▒▒   12 km ↗40 │ │
│ └──────────────────────┘ │
├──────────────────────────┤
│  🗺 Map   📍 Routes   ⭕ Halo │
└──────────────────────────┘
```

- Cards with a thumbnail (`MKMapSnapshotter`, cached), name, distance and elevation gain. Sorted by
  last use.
- **(+) Import:** opens Files. You can also import with "Open with rehalo" from Wikiloc, Komoot,
  Strava, Mail, Safari or AirDrop, which goes straight to the detail screen.
- Swipe actions: rename, share (`.gpx` export) and delete.
- **Empty state:** an illustration, "Import your first route" and two buttons: `[Import GPX]` and
  `[Use demo route]` (GPX included in the bundle).

**Route detail**

```
┌──────────────────────────┐
│ ‹ Routes           ⤴  ⋯  │
│ ┌──────────────────────┐ │
│ │     (route map)      │ │
│ └──────────────────────┘ │
│ Montseny Loop            │
│ 42.3 km   ↗ 860   ↘ 860  │
│ ~2h40 at 16 km/h         │
│  elevation profile       │
│   ╱╲    ╱╲╱╲             │
│ ╱╱  ╲╱╱    ╲╲__          │
│ [      ▶ NAVIGATE     ]  │
└──────────────────────────┘
```

- Elevation profile with Swift Charts (`AreaMark`), using the GPX's `ele` data if present. Without
  elevation, it's hidden.
- `▶ NAVIGATE` selects the route, switches to the Map tab and enters Navigating.

### 4.5 Halo (device control)

```
┌──────────────────────────┐
│ Halo                  ⚙︎  │
│   ⭕  My SmartHalo  │
│       ● Connected · 82%  │
│  [🔋 Show battery on the ring] │
│                          │
│ ┌──────────┐ ┌──────────┐│
│ │ 💡        │ │ 🔒        ││
│ │ Light    │ │ Alarm    ││
│ │ ON       │ │ ARMED    ││ ← large cards; a tap toggles
│ │ ▬▬▬▬▬░ 70%│ │ since 21:04││
│ └──────────┘ └──────────┘│
│                          │
│  Ring & widgets        › │ ← post-MVP (current DisplayView/FitnessView)
│  Settings              › │
└──────────────────────────┘
```

- **Light card:** a tap turns it on or off. A long press or `›` opens a sheet with brightness
  (slider) and mode (steady or blink). The card's color when on is neon.
- **Alarm card:** a tap arms or disarms, with `.success` haptics. It shows the state and the time
  it's been armed since. If it has fired, it turns red ("Motion detected 21:37").
- **Disconnected:** the cards are dimmed and a `Reconnect` button appears.
- The header shows the Halo's name, connection state and battery %. The **"Show battery on the ring"**
  button sends `showStateOfCharge{1,31}` and the ring shows the charge.

### 4.6 Settings

```
Settings
├─ MY HALO
│   Name ................ My SmartHalo ›
│   Pair another Halo ›
│   Forget this Halo   (red, with confirmation)
├─ ALARM
│   Sensitivity ......... Vigilant ›
├─ ACCOUNT
│   Server .............. Not connected ›   (login / whoami / logout)
├─ GENERAL
│   Units ............... Automatic (km / mi) ›
│   Language ............ System ›
│   Keep screen on while navigating  [ ]   (optional, off by default)
└─ ADVANCED ›
    Firmware information (nordic/STM, serial, state)
    Sync clock and language
    Calibrate compass
    Sound & touch (post-MVP)
    Live log
    Demo mode  [ ]
    Firmware update (explainer, deferred)
    Shut down the Halo  (red, with confirmation)
```

### 4.7 Recovery wizard (modal)

Opens when the handshake indicates the Halo needs re-pairing (`.needsRecovery`).

```
 Step 1/3                   Step 2/3                   Step 3/3
┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐
│ Recover your Halo    │  │ Restart the Halo     │  │ ✓ Done               │
│                      │  │                      │  │                      │
│ This Halo has an     │  │ (illustration: a     │  │ Your Halo is yours   │
│ old password. We'll  │  │  micro-USB cable     │  │ again. The new key   │
│ generate a new one   │  │  plugs in underneath │  │ was saved in the     │
│ and save it in your  │  │  and out, on a loop) │  │ Keychain.            │
│ Keychain.            │  │ ◌ Waiting for Halo…  │  │                      │
│                      │  │                      │  │                      │
│ [   Recover   ]      │  │ [ I've rebooted it ] │  │ [   Continue   ]     │
└──────────────────────┘  └──────────────────────┘  └──────────────────────┘
```

- It relies on `recover()` → `.needsReboot` → `reconnectAndFinish()` → `.ready`. Step 2 detects the
  reconnection by itself when it can, and the button stays as a manual alternative.
- The generated password isn't shown by default. It can be seen in Settings › Advanced.

### 4.8 Live Activity / Dynamic Island (navigation)

```
Compact:       [↰ 350 m]                    [43%]
Minimal:       [↰]
Expanded:      ┌──────────────────────────────────┐
               │ ↰ 350 m  turn left               │
               │ 24 km/h · 18.1 km left · 43 %    │
               │ ━━━━━━━━━━━░░░░░░░   [💡 Light]   │
               └──────────────────────────────────┘
Lock Screen:   same as expanded, with the route name and the Halo state.
```

- Updated with ActivityKit from the app in the background (background location), no push. Pace: on
  every turn change or every 50 m and about 10 s at minimum, to save battery.
- The 💡 button is a `LiveActivityIntent`, which runs in the app's process and can use the open BLE
  session.
- On arrival or stop, the activity ends with a summary that lasts a few minutes.

### 4.9 Widget and Control Center — **post-MVP**

Left out of the MVP because of the risk of sending BLE commands from extensions (§7).

- **Home widget** (small/medium, iOS 17 interactive): Halo state (battery), light button and alarm
  button. The medium size adds "▶ Last route".
- **Control Center control** (iOS 18+ only, `if #available`): "Halo light" button.
- See the risk of BLE from extensions in §7.

---

## 5. Key flows

### 5.1 First use
Open → Welcome → Pair (the scan starts on its own) → (recovery if needed) → Permissions → Account
(optional) → **Map** with the hint "Start by searching for a place or importing a GPX" → Search → "Use
demo route".

### 5.2 Sharing a GPX from Wikiloc and navigating
Wikiloc › Download GPX › Share › **rehalo** → the app opens **Route detail** (already saved in the
library) → `▶ NAVIGATE` → Navigating + Live Activity. That's 3 taps inside rehalo.

### 5.3 Daily ride
Open the app → auto-connect to "my Halo" (the chip goes from `◌` to `●` in under 3 s) → magnifying
glass → `▶` on a recent route. The light is turned on from the card, the widget or the Live Activity.

### 5.4 The alarm fires
With the Halo connected and the alarm armed, an alarm report arrives on the UP channel → **local
notification** "🚨 Your bike moved · 21:37" → tapping it opens Halo with the Alarm card in red and
`[Disarm]`. Limitation: it only works while the iPhone keeps the BLE connection (in range and the app
alive in the background).

### 5.5 The Halo disconnects on a ride
The chip changes to `◌ Reconnecting…` → navigation continues on the phone and in the Live Activity →
the app reconnects by itself, with no intervention, and resumes guidance on the ring (it re-sends the
current nav state). After 60 s without success a discreet banner appears, "Halo disconnected —
guidance continues on the phone", which blocks nothing.

---

## 6. Visual system

**Theme:** sporty dark, always dark (`preferredColorScheme(.dark)` app-wide), with high contrast.

| Token | Value | Use |
|---|---|---|
| `bg` | `#0B0D10` | Background |
| `surface` | `#15181D` | Cards and panels |
| `surface2` | `#1F242B` | Raised elements and sheets |
| `stroke` | `#2A3038` | 1 px borders |
| `text` | `#F2F4F7` | Primary text |
| `textDim` | `#8A93A0` | Secondary text |
| `accent` | `#C6FF3D` (neon lime green) | CTA, route, connected state, light on |
| `onAccent` | `#0B0D10` | Text on the accent |
| `warn` | `#FFB020` | Off route, reconnecting, recovery |
| `danger` | `#FF4D4F` | Alarm fired, destructive actions |
| `info` | `#3DD6FF` (cyan) | User position, links |

- Tokens are defined in `Theme.swift` (`Color` + `ShapeStyle`) and in the Asset Catalog. Lime on `bg`
  passes AA contrast comfortably; check `textDim` on `surface` when changing colors.
- **Typography:** SF Pro for text and **SF Pro Rounded** (`.rounded`, `monospacedDigit()`) for metrics.
  Ride metrics from 44 to 64 pt. Everything with Dynamic Type.
- **Components:** `StatusChip`, `ControlCard` (Halo card), `PrimaryButton` (neon), `MetricView` (value
  + unit), `TurnBanner`, `RouteCard` (thumbnail + stats), `EmptyState`.
- **Shape:** 20 pt radius on cards and 14 pt on buttons, surfaces with a 1 px `stroke` and no shadows
  (they don't show in dark mode).
- **Icons:** SF Symbols in `.semibold` weight.
- **Haptics:** `.success` on arming or connecting, `.warning` on leaving the route, `.impact(.medium)`
  on toggling the light.
- **Motion:** a soft pulse on the chip while connecting and a `matchedGeometryEffect` transition from
  the route card to Navigating mode. *Reduce Motion* is respected.
- **Accessibility:** VoiceOver labels on metrics ("twenty-four kilometers per hour"), targets of 44 pt
  or more (56 pt on a ride), and color is never the only indicator (icon + text).
- **Languages:** EN + ES with a String Catalog (`Localizable.xcstrings`). Units come from `Measurement`
  + `MeasurementFormatter`, which respect the locale and the Units setting.

---

## 7. Technical notes and risks

| Topic | Detail | Mitigation |
|---|---|---|
| **iOS 17 minimum** | iOS 17 gives `@Observable`, SwiftUI `Map` with `MapPolyline`, interactive widgets and `LiveActivityIntent`. | Deployment target set in `project.yml`. |
| **BLE from widget / Control Center** (post-MVP) | Extensions don't share the app's BLE session, and creating a connection from the extension is slow or unreliable. | Have intents run in the app's process (`LiveActivityIntent` or `openAppWhenRun` / `ForegroundContinuableIntent`) with the `bluetooth-central` background mode. If it can't be made reliable, the widget becomes "open the app and act". This needs a **spike** before committing to the design. |
| **Live Activity** | Requires a Widget Extension target in `project.yml` (XcodeGen), `NSSupportsLiveActivities` and updates from the app in the background. | `location` background mode while navigating, and rate-limited updates. |
| **Background location** | Navigating with the phone in a pocket needs `allowsBackgroundLocationUpdates` and the *Always* or *When In Use* permission with the blue indicator. | Ask for the permission on first navigation and explain why. |
| **Auto-connect** | Save the peripheral identifier of "my Halo" and use `retrievePeripherals(withIdentifiers:)` + a pending `connect`. | Optionally, CoreBluetooth *state restoration*. |
| **Alarm notification** | Only works while there's a BLE connection. | Explain it in Settings › Alarm. |
| **Route library** | Persistence of GPX + metadata + thumbnails. | SwiftData (iOS 17), with GPX files in Application Support. |
| **"Open with…"** | `CFBundleDocumentTypes` / `UTImportedTypeDeclarations` for `com.topografix.gpx` + `onOpenURL`. | — |
| **Demo mode** | Every new screen must work with `MockTransport` and the simulated location. | Keep the DEMO banner. |

---

## 8. What we take from each reference

| App | What we take |
|---|---|
| **Wikiloc** | Route library with stats (distance, elevation gain), elevation profile and "follow route" with off-route warning. |
| **Komoot** | Map as the protagonist, large next-turn panel and route summary before starting. |
| **Strava** | Large metrics readable on the move, Live Activity and the dark sporty look. |
| **Apple Maps** | Floating status chip, sheets, and center and orient buttons on the map. |
| **Apple Home** | Large device cards: a tap toggles and a long press opens the detail. |

---

## 9. Post-MVP ideas

1. **Home widget and Control Center control** (§4.9), after a spike on BLE from App Intents.
2. **Ride recording** (new): `● Record` on the Map, no route needed. Strava-style summary (map,
   distance, time, average, elevation gain) and local saving + sync with the server if there's an
   account.
3. **History** ("Rides" segment in Routes): list and detail with a map, plus weekly stats.
4. **Fitness:** weekly goals linked to the progress ring.
5. **Integrations:** Strava (OAuth), online rerouting, Apple Health (saving workouts).
6. **Optional automations:** light (on when navigation starts or at dusk) and automatic alarm on
   walking away.

---

## 10. Design decisions

- **Battery:** the Halo tab shows the battery %, plus the "Show battery on the ring" button.
- **Demo route:** a short urban route (~8–10 km) with several turns and at least one roundabout.
- **Units:** metric + imperial. Defaults to the iPhone's region, with an option in Settings.
- **Display name:** **rehalo**.
- **Widget / Control Center:** out of the MVP.
- **Automations when navigating:** none.
- **Map on a ride:** heading-up, with a button to switch to north-up.
