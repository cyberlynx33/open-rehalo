# SmartHalo 2 — The official app's GPX navigation

How the official app (Android 1.18.0) guides the ring along a GPX, found by reverse engineering and
checked against the STM firmware handlers (`RideTask.c`).

- Implementation: `clients/ios/SH2Protocol/Sources/SH2Nav/Navigation/` (`NavStepFactory`,
  `NavBearing`, `NavGuidance`, `NavDirector`) + the encoders in `Commands.swift`; tests in
  `NavigationTests.swift`.

## 1. Overview

**The phone computes everything.** The ring doesn't know where it is or where it's going: it draws
what it's told. The ring's magnetometer plays no part, and the app **doesn't use the phone's
compass**: the rider's direction comes only from **consecutive GPS positions**.

A GPX is navigated in offline turn-by-turn mode:

1. On load, the app turns it into **steps**: one stretch per track turn of ≥ 46°, plus a destination
   step (§2).
2. On every GPS fix (≈ 1 Hz, unfiltered), the app updates the **rider's heading** (§3) and decides
   what to show (§4).
3. That state becomes BLE commands, sent **on every fix** without deduplication (§5).

What the rider sees:

| Situation | Ring | OLED |
| --- | --- | --- |
| Direction still unknown (hasn't covered 3 stretches of > 3.5 m) | spinning standby pointer | "Ride to / calibrate" |
| Off route (including the start, until within < 15 m of the beginning) | **orange arrow** towards the nearest route point, **relative to the direction of travel** | "Go to GPX start" / "Return to route" + distance |
| Returning to the route (15–95 m and heading towards it) | turn arcs towards the entry point | "Turn left/right" |
| On the route, < 95 m from a turn | **green arc** with the turn angle (+ a second arc if the next turn is close) | instruction + distance |
| On the route, far from turns | nothing (the ring goes back to its carousel) | — |
| < 105 m from the end | full destination ring | title + distance |
| Arrival (< ~50.5 m from the end) | full green ring for 10 s | title |

## 2. GPX → steps

- Reads **only lat/lon** from all `<wpt>` and all `<trkpt>` (all tracks and segments, concatenated).
  **Ignores `<rte>`**. Uses waypoints only if there are **strictly more** of them than trackpoints.
- **Turn detector** (3 m threshold): window A = P[i−1] … B = P[j]; the vertex M is the intermediate
  point with the largest |Δ(bearing A→K, bearing K→B)| (bearings in whole degrees, −180…180). While
  M is < 3 m from A or B, the window grows. It's a turn if |Δ(bearing A→M, bearing M→B)| ≥ **46°**:
  the stretch is cut at M. Points the window skips are discarded (stretches end up decimated).
- Resulting steps: a first stretch (type 15, no angle), one type 15 step per turn
  (`angles = [bearingAfter − bearingBefore]` in −180…180, + = right; entry = vertex; a right-turn
  instruction if the angle is > 44, otherwise left) and a **destination** (type 0) at the last point.
- Only types 15 and 0 appear: **no** slight/sharp turns, roundabouts or U-turns.
- Quirks kept: the attempt to mark the first step as DEPART is lost (it edits a copy); with no turns,
  the single stretch's distance stays at 0.

## 3. Rider direction

- Sample = bearing from the previous fix → new fix, only if **both** fixes have accuracy **< 35 m**
  and are **> 3.5 m** apart. The previous fix is always updated (at 1 Hz, below ~12.6 km/h there are
  no samples).
- **Current heading**: circular mean of 3 samples that differ by ≤ 40° (searching from newest to
  oldest); earlier ones are discarded. **"As the crow flies" heading**: mean of the 3 newest.
  999 = unknown.
- Quirk kept: as soon as a current heading exists, the crow-flies calculation reuses the current
  sample list (the same sample goes in twice).
- The current heading returns to 999 when each turn completes; the crow-flies heading isn't reset
  during the whole route, so the "Ride to calibrate" wait only happens at the start.

## 4. Per-fix engine

Distances: haversine (R = 6371 km). Bearings: great circle rounded to whole degrees. Projection onto
the route in degrees without latitude correction (as in the official app).

**Off route** (the route starts this way): the rider is marked off route if the distance to the
current stretch is > accuracy + 20 m (at once if > 50 m, otherwise on the 2nd fix in a row) or if
heading > 40° against the stretch's direction. Then, with target = nearest point of the current or
next stretch (or the start of the stretch, if the rider hasn't been on the route yet):

- **< 15 m**: back on the route ("info" sound).
- **< 95 m and heading towards it** (bearing within 40°): turn arcs towards the route (`sameTurn`).
- Otherwise: **pointer** with angle = bearing(fix → target) − crow-flies heading (not normalized,
  + = right), distance = distance to target.

**On the route**, relative to the next turn:

- Progress: 100 at ≤ 20 m (destination 50 m), 0 at ≥ 95 m (105 m), linear in between.
- Animation active if < 95 m remain (destination < 105 m) or the turn has already started. On start:
  progress sound. On reaching progress 100: turn started ("turn now" sound, which in the official app
  is silence).
- Second arc when the following turn is also close (its progress ≥ 1).
- Turn completed when, once started, the rider is again > 20 m from the vertex, or the current
  heading is within 40° of the exit bearing and of the vertex → rider bearing. (The official app's
  distance-history check never fires: steps are copied on every fix.)
- **Arrival**: < ~50.5 m in a straight line from the last point, except early in the route (step
  index ≤ n/2 − 1 and, with 6+ steps, < n − 5), so that a loop doesn't end at its own start.

## 5. Commands (each fix)

Order per fix: remove animations (`[1,23]` pointer, or `[1,23]`+`[1,3]` for the rest), then:

- Off route → `navPointerStandby` if there's no heading at all, otherwise an orange `navPointer`
  (30,255,255) with the angle, the distance and "Go to GPX start"/"Return to route".
- On the route / returning, only while the animation is active → `navAngle` (green 67,255,255;
  `sameTurn` if not yet on the route) or destination `nav`; plus its sound, when due.

Layout of each command: [`commands.md`](commands.md).

| Moment | Commands |
| --- | --- |
| Start | `[1,32, 2, title, 0]` + `[1,36, 0, FD 02 00 00]` (with no ring: on connection) |
| Arrival | `[1,23]`, `[1,3]`, destination sound, `[1,1, 43 FF FF, 0, 100, 0×4, title, 0]`, `[1,3]` after 10 s |
| User stop | `[1,23]`, `[1,3]` |
| Ring shows its Navigation card | `[1,35, 0, FD 02 00 00, D(4), ang(2), 00 00 DC, text, 0]` |

- Colors: progress hue 17 + p/2 (17 far … 67 on arrival); turn 67/255/255; caution 38/234/249;
  warning 253/237/255; return pointer 30/255/255.
- Sounds (`[2,0, vol, 0, track]`, default volume 50): progress 293/391 Hz; "turn now" 106 ms of
  silence; destination 261–523 Hz; info (back on route) 261/349/329 Hz.
- Texts (English only in the official app): "Continue down", "Turn left", "Turn right", "Go to GPX
  start", "Return to route", "You have arrived at your destination"…

## 6. Deliberate differences in rehalo

| Official app | rehalo | Why |
| --- | --- | --- |
| Guidance is created with the position at GPX load time | with the route's first fix | iOS has no guaranteed earlier position |
| If you're not at the start, it asks whether to begin at the nearest step (which takes you to the start of that stretch) | > 500 m from the start it asks: **lead me to the start** / **nearest point** / **on my own** (§7) | the nearest stretch can be behind you |
| Destination title from reverse geocoding | route name ("Your destination" if missing); for destinations (§7), the place name | — |
| Heartbeat `[1,9]` every 60 s / `[1,10]` | not sent | the SH2's STM firmware doesn't implement it |
| Negative distances ("distance − 50") sent as is | sent as 0 | raw values would set the imperial bit |
| Texts longer than 29 characters | trimmed to 29 | the firmware stores 30 bytes (and the intro overflows) |
| Android's WGS84 ellipsoid distance | haversine | a difference of centimeters |
| GPX with only `<rte>`: no navigation | uses the route points | navigable instead of empty |
| Roundabouts (Valhalla, online) | none | a GPX never produces roundabouts |
| Back on the route with nothing to show, only `[1,23]` | also `[1,3]` | with only `[1,23]`, the OLED stays on "Return to route" until the next turn (`RideTask.c:494`) |
| Typographic punctuation as `?` | `’`, `“`, `–`, `…` become their Latin-1 equivalent | the OLED shows all of Latin-1, and Apple uses them ("Carrer d’Aragó") |

## 7. rehalo additions: destinations, compass and getting to the start

No routing server: routes are computed by **MapKit** (`MKDirections`), with the profile the rider
picks: City (`.cycling`, or on foot if Apple has no bike route), Road (`.automobile` avoiding
motorways and tolls) or Trails (`.walking`). Everything else is the engine above, with its logic
unchanged.

- **Destination with a route** (search or touch and hold the map → NAVIGATE): the turns come from
  Apple's steps (`RoutedSteps.swift`), not from the GPX detector. The official app didn't use it here
  either: it rode on typed Valhalla steps. MapKit only gives geometry and text, so:
  - The angle comes from the geometry, with the heading read 20–40 m from the manoeuvre: a rounded
    corner gives its whole angle.
  - Under 20° it's a change of street name and merges into the previous stretch, unless the caution
    state changes or it's a roundabout.
  - The text is shortened to the street (`NavDirector.shortInstruction`: "Turn right onto Carrer
    Major" → "Carrer Major"). When returning to the route it stays "Turn left/right".
  - Apple doesn't document which end of the polyline its instruction belongs to. It's read from the
    route: a last step of 1 m or more means the end, a shorter one means the start. This only decides
    which text goes with which turn.
  - Roundabouts are recognised by their text and are a normal arc with the net angle, read where the
    path stops turning, and `Exit 2 · Carrer X` on the OLED. The ring's roundabout commands need each
    exit's angle, which MapKit doesn't give.
  - A step on foot in a route that isn't, or with an Apple notice, uses the ring's caution colour.
  - If the steps don't add up to the route's length (±10 %), they're ignored and the detector takes
    over.

  Off route: the usual orange arrow, **no recalculation**.
- **Compass** (`CompassDirector`, the official app's "as the crow flies" mode): on every fix,
  `navPointer` with angle = bearing(fix → destination) − rider heading, distance − 50, title = place
  name and color by progress (+50 m); `navPointerStandby` while there's no heading; arrival at
  < ~50 m → `[1,23]` + destination sequence. Only difference: with the rider slow or stopped
  (< 1.5 m/s) the app uses the **iPhone's compass** heading, which takes priority over GPS. Stop: only
  `[1,23]`, as in the official app.
- **Far from a GPX's start** (> 500 m when pressing NAVIGATE):
  - *Lead me to the start*: an Apple route to the first point, with the chosen profile, **chained** in
    front of the GPX in a single `NavDirector` (same route id → the Live Activity continues); "Towards
    the start · X" screen. It rides on the detector: each turn takes the text of the nearest Apple
    instruction to its vertex (≤ 30 m).
  - *Start at the nearest point*: `NavGuidance.joinNearestStretch` picks the nearest stretch and marks
    the origin as reached, so the ring leads to the nearest point of the route.
  - *Go on my own*: the official behavior ("Go to GPX start" arrow).

## 8. The screen

**The screen says what the ring says.** In the official app both read the same guidance state, and so
they do here: `RideEngine` (`SH2Nav/Ride/`) takes the next turn, the distance, the off-route state and
the arrow from `NavGuidance`. Only progress, distance left and speed are the screen's own. The distance
shown is the ring's: 25 m (destination: 50 m) before the manoeuvre, as in the official app.

A known consequence: on a GPX the screen inherits the limits of the original detector, which don't
affect a destination with a route (§7). Limits kept on purpose, to behave like the official app:

| Limit | Effect |
| --- | --- |
| Detector of ≥ 46° per vertex | No warning at rounded corners (radius ≥ 12 m with points every ≥ 3 m) or at gentle forks |
| Same detector on recorded tracks | False turns at low speed |
| No heading samples under ~12.6 km/h | The arrow uses a frozen heading |
| No heading since the start | No off-route warning, even more than 100 m away |
| Arrival guard only with ≥ 6 steps | A loop or an out-and-back with ≤ 3 turns ends as it starts |
| The current step only moves forward | After a shortcut or going back, it stays "off route" and may never arrive |
| Riding it backwards | Detected late, on leaving the current stretch |
| Roundabouts in GPX mode | No useful indication |

The "matched" engine, [`MAP_MATCHING_SPEC.md`](../MAP_MATCHING_SPEC.md) (the default), lifts four of these limits
(the step that only moves forward, no off-route warning without a heading, the arrival guard, and riding
it backwards), adds a wrong-way warning, and keeps this behaviour available as the "classic" engine.

And from the firmware:

- The pointer is only drawn with the bike moving (`interruptCount ≥ 15`, `RideTask.c:458`), and
  disappears about 25 s after stopping. **Testing at home with the ring still, the app says "return to
  route" and the ring draws nothing**: it isn't a bug. Turn arcs do show.
- The OLED rounds the distance to tens and counts towards it: 38 m on screen is 40 on the ring.
- It shows all of Latin-1, but trims to 118 px with `...`: about 18–20 characters, never the 29 of
  `navText` (`Avinguda de Franc...`).
- Between turns it isn't off: the Navigation card draws a white arc towards the next turn.
