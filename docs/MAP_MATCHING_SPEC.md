# rehalo — Map matching and wrong-way detection (spec)

Status: **implemented, to be road-tested** (`SH2Nav/Ride/RouteMatcher.swift`, `WrongWayDetector.swift`,
`TravelDirection.swift`, hooks in `NavGuidance` / `NavDirector`, tests in `MatchedRideTests.swift`). This
spec is the implementation map for the "matched" navigation engine: each section is a unit of work with
the files it touches. Where building it changed the design, the text says what was built.

## 1. Why

The ring guidance (`NavGuidance`, a 1:1 port of the official app, [`protocol/navigation.md`](protocol/navigation.md))
locates the rider with three rules: the projection onto the **current stretch** only, a step index that
**only moves forward**, and "off route" when more than accuracy + 20 m from the stretch or riding more
than 40° off its direction. Arrival is a straight-line radius with a step-index guard. That causes these
known limits (`navigation.md` §8):

| Limit | Effect | This spec |
| --- | --- | --- |
| The current step only moves forward | After a shortcut or going back, it stays "off route" and may never arrive | Lifted (§6) |
| No heading since the start | No off-route warning, even more than 100 m away | Lifted (§5: off route is distance-based) |
| Arrival guard only with ≥ 6 steps | A loop or an out-and-back with ≤ 3 turns ends as it starts | Lifted (§7) |
| Riding it backwards | Detected late, on leaving the current stretch | Lifted (§8) |
| *(not in §8)* accuracy + 20 m or 40° rule | False "off route" alarms with urban GPS noise | Lifted (§5) |
| No heading samples under ~12.6 km/h | The ring's pointer uses a frozen heading | Not in scope (§13) |
| ≥ 46° turn detector, roundabouts in GPX mode | Missed gentle turns, no roundabouts | Not in scope (§13) |

The design borrows ideas, not code, from how Komoot 2026.44.2 does it: a probabilistic matcher over the
whole route (distance × direction × progress), hysteresis with persistence for leaving the route, a
vector-based wrong-direction detector, and arrival measured along the route with a coverage guard.

## 2. Decisions

1. **Layer on top.** The matcher decides where the rider is on the route, whether they are on or off it,
   which stretch they are on, and arrival. `NavGuidance` keeps all the ring rendering: arcs, pointer,
   sounds, commands, and its timing (95 m / 20 m).
2. **Two engines.** `matched` (this spec) is the default; `classic` (today's behaviour, byte-identical
   commands and traces) is selectable in Settings › Advanced. Compass rides never use the matcher.
3. **Wrong way:** the ring shows the U-turn glyph, the phone shows a banner with **Invert route** and
   **Ignore**, plus a haptic.
4. **Off route, "balanced":** leave beyond max(30 m, 2 × accuracy) for ≥ 5 s; rejoin within
   accuracy + 15 m for ≥ 3 s.
5. **Out of scope:** rerouting, speed-based turn timing, the pointer's heading, GPX turn classification
   (§13).

## 3. Architecture

```
RideFix ─► FixGate + odometer ─► TravelDirection ─► RouteMatcher ─────────► NavMatch ─┐
                                                    │ candidates, scores               │
                                                    │ RouteStatus (on/off…)            ▼
                                                    │ coverage, arrival      NavDirector.update(_:match:wrongWay:)
                                                    └► WrongWayDetector ──► WrongWay ──┤   (wrong-way layer, arrival)
                                                                                       ▼
                                                              NavGuidance.update(_:match:)  (hooks, §6)
                                                                                       ▼
                                                                         ring commands (unchanged encoders)
RideEngine.snapshot ◄── matcher (along, progress) + guidance (next turn, pointer) ──► screen, Live Activity
RideTrace ◄── header + every fix (+ match block, events)
```

- Everything new lives in `SH2Nav` (Foundation only, tested on macOS in CI and buildable on Linux):
  `Ride/RouteMatcher.swift`, `Ride/TravelDirection.swift`, `Ride/WrongWayDetector.swift`.
- `RideEngine.init(…, engine: Engine = .classic)`. The default keeps every existing test unchanged; the
  app passes `.matched` unless the setting says classic. `RideEngine(compassTo:…)` has no matcher.
- In classic mode `NavDirector.update(_:)` and `NavGuidance.update(_:)` are called exactly as today. All
  hooks sit behind a non-nil `NavMatch`.

## 4. Inputs: fix gate, odometer, travel direction

**Files:** `Ride/TravelDirection.swift` (new), the gate and odometer inside `RouteMatcher`.

### 4.1 Fix gate
- A fix is **accepted** when `horizontalAccuracy` is in 0…40 m and `time` is later than the last accepted
  fix. Otherwise the matcher returns `status = .hold` for it (§6.3); `nil` would mean "classic".
- `NavGuidance` still receives every fix, as today (its own bearing samples already skip > 35 m).
- **Working accuracy** `a` = median of the last 5 accepted accuracies, at least 5 m. Every threshold
  below uses `a`, so a single bad fix doesn't move them.
- All timers use `fix.time`, never the wall clock, so replays are exact.

### 4.2 Odometer
The matcher keeps its own distance ridden: the sum of distances between consecutive accepted fixes,
skipping a step longer than `vMax·Δt + acc₁ + acc₂` (`vMax` = 25 m/s). It is separate from the screen's
distance ridden (which runs later, with a 50 m gate).

### 4.3 Travel direction
The rider's direction from displacement, not from fix-to-fix bearings (which give nothing under
~12.6 km/h at 1 Hz):

- Walk back from the newest accepted fix `pₙ` through older ones `pₖ`, adding the unit vector of
  `pₖ → pₙ` each time. Stop at the first `pₖ` with `|pₖ pₙ| ≥ B`, `B = max(15 m, 1.2·(accₖ + accₙ))`.
- Valid when that distance is ≤ 150 m and the coherence `|Σ unit vectors| / count` is ≥ 0.85. Direction
  = bearing `pₖ → pₙ`; **length** = `|pₖ pₙ|`.
- Fallback: GPS `course` when speed ≥ 2 m/s and the course is valid.
- `vector(over: W)` returns the displacement over the last `W` metres of path (used by §8).
- History: the last 60 s of accepted fixes.

This estimate feeds the matcher and the wrong-way detector only. The ring's pointer keeps `NavBearing`.

## 5. RouteMatcher

**File:** `Ride/RouteMatcher.swift` (new). **Geometry:** `RideEngine.route` (`points`, `cumulative`).
`navPoints == points` for every ride (`GPXFile.navPoints`, `RouteGeometry.chain`), so the ring's steps,
the matcher and the screen share one "along" (metres from the start).

### 5.1 Route direction helper
`routeBearing(at s, over W)` = bearing from `coordinate(at: s − W)` to `coordinate(at: s)`; near the
start it uses `[0, W]`. It is computed along the route, never per segment, because GPX files have
zero-length segments. Add it to `RouteGeometry`.

### 5.2 Candidates
Every accepted fix searches the **whole route** (O(n); a 20 000-point route is well under the budget, §12):

1. Project the fix onto every segment with the local planar projection `RouteGeometry.match` already
   uses. That gives, per segment, `d` and `along`. Let `d_min` be the smallest.
2. **Passes:** maximal runs of consecutive segments with `d ≤ D`, `D = max(2.5·d_min, 40 m)`. A pass is
   **split** wherever the route reverses: `|angleDelta(routeBearing(s − 15, 15), routeBearing(s + 15, 15))| > 120°`.
   This separates the two legs at the tip of an out-and-back and on hairpins.
3. One **candidate** per pass: its point with the smallest `d`, giving `along`, `d`, `point`, `segment`.
4. Keep candidates with `d ≤ max(2.5·d_min, 40 m)`, at most 8. When the rider is far off route this
   leaves the nearest point, which the pointer needs.

### 5.3 Scores
Each candidate gets factors in 0…1. A factor that can't be computed is left out; it is left out for every
candidate on that fix, so the ranking stays fair.

| Factor | Formula | Notes |
| --- | --- | --- |
| `s_dist` | `exp(−d/τ)`, `τ = max(20, 1.5·a)` | Exponential rather than Gaussian, so one GPS outlier doesn't sink the right candidate |
| `s_dir` | `(1 + cos Δ)/2`, Δ = travel direction − `routeBearing(along, W)` | `W` = travel length clamped to 20…60 m. Left out without a valid travel direction |
| `s_prog` | `1 / (1 + (e/σp)²)`, `e = along − (A₀ + O)` | `A₀` = along of the last confident match, `O` = odometer since then. `σp = 25 + 0.25·O + vMax·gap`, `gap` = seconds without accepted fixes beyond 3 s |
| `s_prior` | `1 − 0.5·along/length` | Only before the first confident match: favours the start, as the official app does |

`p = (0.2 + 0.8·s_dist) · (0.4 + 0.6·s_dir) · (0.6 + 0.4·(s_prog or s_prior))`. The floors stop one factor
from vetoing a candidate on its own.

### 5.4 Tracking and confidence
- **The anchor** is the last confident match, or where the rider joined the route: joining is itself a
  decision on where the rider is, and it has to be, because two laps of a circuit look the same until
  continuity tells them apart. The anchor always scores `s_prog`; off the route it stays, as a soft
  score whose `σp` grows with the distance ridden and the GPS gaps.
- **Tracking** = on the route with an anchor from the last 30 s. While tracking, candidates with
  `|e| > 3σp` are **discarded** (continuity as a hard rule). This is what separates laps of a circuit and
  same-direction overlaps, where distance and direction can't. If every candidate is discarded, the fix
  is not confident. If the nearest pass is discarded for 3 fixes in a row while the kept best is further
  than `R` (a shortcut), the anchor moves to the nearest pass (the most continuous of those as near).
- The **best** candidate is the highest `p`. It is **confident** when all of these hold:
  - `d_best ≤ R` (§5.5);
  - it is the only candidate, or `p₂ / p_best ≤ 0.5`;
  - it passed the tracking gate, or tracking hasn't started.

  There is no absolute threshold on `p`: with the floors, a candidate 8 m away could never reach 0.8.

### 5.5 Route status
Thresholds per fix: `L = max(30, 2a)` (leave), `R = clamp(a + 15, 15, 0.75·L)` (rejoin). Distances are
`d_min`, to the nearest point of the route anywhere.

| From | To | When |
| --- | --- | --- |
| *start* | `off` | The ride starts off route, as in the official app |
| `off` | `on` | Not joined yet, `along_best ≤ 50 m`, `d < R` and the join allowed: at once, as the official app joins at its start. Until the first join, a candidate within the start window and `R` is taken as the best even where another pass is as near (a loop's end meets its start) |
| `off` | `rejoining` | `d_min < R` and the join is allowed (below) |
| `rejoining` | `off` | `d_min ≥ R`, or the join stops being allowed |
| `rejoining` | `on` | Held for ≥ 3 s and ≥ 2 accepted fixes |
| `on` | `leaving` | `d_min > L` |
| `leaving` | `on` | `d_min ≤ L` |
| `leaving` | `off` | `d_min > L` for ≥ 5 s, or `d_min > 2L` on 2 accepted fixes in a row (one multipath jump isn't enough) |

`leaving` is reported as `on`, so the ring keeps its turn guidance until the exit is confirmed.

**When a join is allowed:**
- *Direction*, when the travel direction is valid: `s_dir(best) ≥ 0.7`, meaning the rider rides along the
  route. Crossing it at right angles never joins. A rider who rides along it the wrong way (`s_dir ≤ 0.25`
  for ≥ 5 s) also joins, and the wrong-way detector takes over (§8). A fix with no direction (noise, a
  stop) keeps the reversal's clock running; riding along the route or across it resets it.
- *Before the route has been reached* (`hasReachedOrigin` false), one of these must also hold:
  - `along_best ≤ 50 m` (at the start);
  - `joinNearest` ("Start at the nearest point");
  - the direction rule above held on the last 2 fixes (joining mid-route, as Komoot does).

  Riding it backwards joins before the route has been reached only when the ride **began at its end**
  (a candidate with `along ≥ length − 50 m` within `R` before the rider had moved 50 m), or with
  `joinNearest`. That covers a loop ridden the other way round and a route loaded the wrong way: the
  warning offers to invert it. A rider who reaches the start along the first stretch the other way doesn't
  join (no warning): they turn round at the start.
- *While on a lead-in:* joining mid-route is disabled until `along ≥ leadInLength`. Apple's lead-in often
  ends on a street the GPX uses again later.

### 5.6 Output
```swift
public struct RouteMatch: Equatable, Sendable {
    public enum Status: String, Sendable, Codable { case on, off, rejoining, hold }
    public var status: Status
    public var best: Candidate?          // along, distance, point, segment, p, factors
    public var candidates: [Candidate]   // sorted by p, at most 8
    public var confident: Bool
    public var distanceToRoute: Double   // d_min
    public var travel: TravelDirection.Estimate?
    public var coverage: Double          // 0…1, §7
    public var arrived: Bool             // §7
}
```

## 6. Steps: from along to `NavGuidance`

**Files:** `Navigation/NavSteps.swift`, `Navigation/RoutedSteps.swift`, `Navigation/NavGuidance.swift`.

### 6.1 Where each manoeuvre is (`stepAlong`)
`stepAlong[i]` = along of manoeuvre `i` (`steps[i].entrance`). `stepAlong[0] = 0` and
`stepAlong[n−1] = length`, set directly, which also covers loops whose start is their end.

- **GPX:** the turn detector records the route index of each vertex it splits at (`maxIdx` in
  `NavStepFactory.pathSplits`, NavSteps.swift:132) in a new `NavStep.routeIndex`. Then
  `stepAlong[i] = cumulative[routeIndex]`, exactly. (`startIndex` can't be used: it counts decimated points.)
- **Apple routes:** project each entrance onto the route, searching forward from `stepAlong[i−1]`, nearest
  within 25 m. If that fails, use `stepAlong[i−1]` + the length of the Apple step. Apple's step polylines
  can differ from the route by up to 10 % (`RoutedStep.covers`).
- **Lead-in chains:** the same rules apply to the chained geometry; the lead-in's steps come first.

### 6.2 Step sync
Inside `processOfflineStepByStep`, right after the clamp at NavGuidance.swift:139, compare against the
index **as it was when the fix started**. Let `k = max{ i : stepAlong[i] ≤ along_best }`, clamped to n−2
(index n−1 would make `steps[cur+1]` crash and fire the index-based completion at :167).

| Situation | Action |
| --- | --- |
| Not confident, or wrong way suspected | Nothing |
| `k == cur` | Nothing |
| `k == cur + 1`, less than 30 m past `stepAlong[k]` | Let the official completion run, so the "turn now" animation plays |
| `k == cur + 1`, 30 m or more past | Forced `processStepComplete(next)` |
| Any other `k` (2 or more ahead, or behind) | After **3 consecutive confident fixes** with the same `k` (behind also needs `along < stepAlong[cur] − 30 m`, so a wobble at a red light just past a corner doesn't flip it): **jump** |
| Off route (`offThePath`) | Set the index at once, so the arcs that turn the rider onto the route aim ahead, not behind. Behind only past the same 30 m: coming back to a missed corner, GPS noise either side of it would flip the step back and forth |

A **jump** does all of the following:
- sets `currentStepIndex = k`;
- clears `turnStarted`, `stepAnimationStarted` and `nextTurnAnimationStarted`;
- resets `display.thisTurn` and `display.nextTurn`;
- calls `bearing.clearCurrent()`;
- queues the `.angle` removal once, only if `currentType` is `.angle` or `.destination` and it isn't
  already queued (the classic path can queue it twice).

**Gating the official completion:** in matched mode, `turnComplete` (NavGuidance.swift:234, :568) only
counts when `along ≥ stepAlong[cur+1] − 5 m`. Today, once a turn has started, being more than 20 m from
the corner completes it in any direction, including drifting back at a light.

### 6.3 Hooks in `NavGuidance` (matched mode only)

| Where (NavGuidance.swift) | Classic | Matched |
| --- | --- | --- |
| `update` | `bearing.update` + `processOfflineStepByStep` | Same, with the match. On `.hold`: `bearing.update` only; the display is left as it was, and the director re-sends the current animation as usual |
| :139, after the clamp | — | Step sync (§6.2) |
| :146 `checkForUserReroute` | Accuracy + 20 m / 40° rules | Replaced: `.off` sets `offThePath = true`. Nothing else may clear `offThePath` |
| :283 `executeGPXCompassMode` | Target = `closestLocationOnNearbyPath` | Target = `best.point`. On `.rejoining`: return at once, keeping what the ring shows (no pointer flash during the 3 s wait) |
| :292 `if d < 15` | Rejoin by distance | Condition becomes `status == .on`. The branch body stays: it is the only code that removes the pointer, plays "back on route" and resets the animation state |
| :305 `else if d < 95 && headingToPath` | Arcs onto the route | Unchanged, with the matched target |
| :311–313, :363 | Index `+= 1` | Disabled: the index comes from §6.2 |
| :167 `currentStepIndex ≥ n−1` | Completion by index | Disabled: arrival comes from §7 |

API:
```swift
public struct NavMatch: Equatable, Sendable {
    public var status: RouteMatch.Status
    public var target: NavLocation       // best candidate point
    public var along: Double
    public var confident: Bool
    public var wrongWaySuspected: Bool   // freezes step sync
}
public mutating func enableMatching(stepAlong: [Double])   // once, at the first fix
public mutating func update(_ fix: NavLocation, match: NavMatch)
mutating func syncStep(_ match: NavMatch, previousIndex: Int)  // §6.2, internal
```
`joinNearestStretch` (NavDirector.swift:156) still runs at the first fix with `joinNearest`: it marks the
origin reached, so the pointer says "Return to route", and the step sync corrects its stretch. Until the
rider joins (and without `joinNearest`) the target is the route's start, as in the official app.

## 7. Arrival and coverage

- **Coverage:** the union of along intervals between consecutive confident matches, with gaps ≤ 100 m. A
  match only counts when `s_dir ≥ 0.5` or the direction is unknown, so riding the route backwards covers
  nothing.
- **Arrival:** `on`, confident, `length − along ≤ 50 m` (the official radius is ~50.5 m), and coverage
  ≥ 10 % of `length − joinAlong`, where `joinAlong` is where the rider first joined. A rider who joined
  near the end can still arrive.
- **On a loop** (its end within 50 m of its start), coverage ≥ **50 % of the whole loop**. A rider who
  sets off on the loop's last stretch rides it towards the start, joins it there (aligned) and would
  otherwise "arrive" at the start: with 10 % of what was left, after 19 s in the simulation (§12.5). Past
  the start, continuity re-anchors on the loop's first stretch and the steps jump back to 0.
- In matched mode this replaces **both** of the director's arrival paths: `g.isComplete` at
  NavDirector.swift:189 and `g.hasArrived` at :193. The arrival commands (`navigationCompleted`) don't change.

## 8. Wrong-way detector

**File:** `Ride/WrongWayDetector.swift` (new).

- **Active only:** in matched mode; with status `on`; 20 s or more into the ride; at speed ≥ 1 m/s; past
  the lead-in (`along ≥ leadInLength`). Never in Compass.
- **Measure, each accepted fix:**
  - `T` = travel `vector(over: 40 m + mean accuracy)`, required to be at least 20 m + mean accuracy long;
  - `Rv` = `routeBearing(along_best, over: |T|)`, the route's direction averaged over the **same length**
    (so switchbacks don't trigger it);
  - `c = cos(T, Rv)`.
- **Suspected:** `c ≤ −0.5`, and no candidate within `L` has `c ≥ 0.5`. On an out-and-back the matcher
  switches to the other leg, which isn't wrong way.
- **Confirmed:** suspected, and `along_best` dropped by at least 0.5 × the odometer over the last ≥ 40 m,
  on 2 evaluations ≥ 3 s apart. The (odometer, along) history only holds fixes on the route since the
  rider last joined it: going off route clears it.
- **Ends when any of these happens:**
  - `c ≥ 0.4` on 2 fixes (or the GPS course agrees with the route at ≥ 2 m/s);
  - `along` rises by 30 m;
  - status goes `off` (the pointer takes over);
  - the route is inverted (§9.3).
- **Ignored** (§9.2): stays silent until the episode ends; a new episode can warn again.

Output: `WrongWay { state: none | suspected | confirmed | ignored, since: Double }`. `suspected` freezes
step sync (§6.2).

## 9. Wrong-way UX

### 9.1 Ring (a layer in `NavDirector`)
`NavGuidance` rewrites `currentType` on every fix, so the U-turn is drawn by the director, on top:

- **On entering `confirmed`:** `stopNavCommand()`, then
  `nav(stepType: 8, progress: 100, distance: 0, text: "Turn around", colour: NavColour.warning)`, then
  `soundPlay(NavSound.wrongWay)`. Whether progress 100 draws the full glyph needs checking on a real ring.
- **While confirmed:** the U-turn command is re-sent on every fix, like other animations. The guidance
  still updates its state, but its commands and sounds are dropped (its `typesToRemove` are consumed).
- **On exit:** `navOff`; the guidance's own commands resume on the next fix.
- **`carouselCard()`** (NavDirector.swift:202): angle 180°, distance 0, "Turn around".
- **New sound** `NavSound.wrongWay`: two falling notes, 440 Hz for 150 ms then 330 Hz for 250 ms:
  `[0x01,0xB8,0x00,0x96, 0x01,0x4A,0x00,0xFA]`. There is no warning sound in the official set.

### 9.2 Phone
- New `RideSnapshot.wrongWay: Bool?` and `canInvert: Bool?` (nil in the classic engine), published by
  `GuidanceController` and carried into `NavState`. The Live Activity needs no new field: it shows turn
  `wrongWay`, symbol `arrow.uturn.backward` and "Wrong way" with the off-route tint. Don't reuse
  `TurnKind.uTurn`: it means a turn of 165° or more in the route.
- **`NavigatingView` banner**, in the warning colour:
  - "Wrong way" / "Vas en sentido contrario";
  - **Invert route**, shown when `canInvert`;
  - **Ignore**.
- **Haptic:** `.warning` on entry, while the app is in the foreground, at most 3 times per ride and
  ≥ 30 s apart. The count resets when a warning ends with the rider riding the right way (not when it is
  ignored).
- No local notification: the ring is the main channel (open question, §13).
- New strings in `Localizable.xcstrings` (EN/ES): "Wrong way", "Invert route", "Ignore", "Turn around"
  (the ring's OLED text stays English, like the official texts).

### 9.3 Invert route
**`canInvert`** = a GPX ride (no Apple steps and no Apple instructions), not Compass, and any lead-in
already finished (`toStart == nil`). An Apple route only warns: its destination is fixed.

New `GuidanceController.invert()`. It must **not** go through `start` / `begin`, which would send
`navOff`, start a new trace file, reset the elapsed time and the distance ridden, and replay the intro:

1. Build the reversed route: same id and name; reversed `points`, `elevations` and `navPoints`. Bump a
   `routeRevision` counter so the map redraws (`GPXRoute ==` only compares ids).
2. `RideEngine.inverted()`:
   - builds steps on the reversed geometry;
   - seeds the matcher already tracking at `along′ = length − along`, status `on`, origin reached;
   - syncs the guidance to the step at `along′`;
   - keeps the screen's distance ridden, speed and fix count.
3. Send `stopNavCommand()` to clear the U-turn. No intro.
4. Record an `invert` event in the trace (§10). Elapsed time, the summary and the Live Activity carry on.

"Ignore" calls `RideEngine.ignoreWrongWay()` and records an `ignoreWrongWay` event.

## 10. Settings and ride trace

- **Setting:** `AppSettings.navigationEngine`, key `sh2.nav.engine`, values `matched` (default) and
  `classic`. In `AdvancedSettingsView` as a "Classic navigation" toggle (off by default). It applies from
  the next ride on.
- **`RideTrace`** (no version bump: only new optional keys, which the encoder omits when nil, so classic
  traces stay byte-identical):
  - `Header.engine: String?`;
  - `Entry.match: MatchTrace?` with `status`, `along`, `distance`, `confident`, `step`, the top 3
    candidates as `[along, d, p]`, `travel` (bearing), `wrongWay` and `coverage`;
  - `Entry.event: String?` (`invert`, `ignoreWrongWay`). A replay rebuilds an inverted ride by reversing
    the header's points at that entry.

## 11. Parameters

All are constants in one `RouteMatcher.Parameters` struct, to be tuned with recorded rides.

| Name | Default | Used in |
| --- | --- | --- |
| Max accepted accuracy | 40 m | §4.1 |
| Working-accuracy window | median of 5 fixes, minimum 5 m | §4.1 |
| `vMax` | 25 m/s | §4.2, §5.3 |
| Travel baseline `B` | max(15 m, 1.2·(accₖ + accₙ)), ≤ 150 m | §4.3 |
| Travel coherence | ≥ 0.85 | §4.3 |
| Course fallback speed | ≥ 2 m/s | §4.3, §8 |
| Pass width `D` / candidate cut-off | max(2.5·d_min, 40 m) | §5.2 |
| Pass split (route reversal) | > 120° within ±15 m | §5.2 |
| Max candidates | 8 | §5.2 |
| `τ` (distance score) | max(20 m, 1.5·a) | §5.3 |
| `σp` | 25 m + 0.25·O + vMax·gap | §5.3 |
| Score floors | 0.2 / 0.4 / 0.6 | §5.3 |
| Tracking timeout / gate | 30 s / \|e\| > 3σp | §5.4 |
| Confidence margin | p₂/p_best ≤ 0.5 | §5.4 |
| `L` (leave) | max(30 m, 2a) | §5.5 |
| `R` (rejoin) | clamp(a + 15, 15, 0.75·L) | §5.5 |
| Leave persistence | 5 s, or > 2L on 2 fixes | §5.5 |
| Rejoin persistence | 3 s and 2 fixes | §5.5 |
| Join direction | s_dir ≥ 0.7 (anywhere: ≥ 0.75 on 2 fixes); wrong-way join ≤ 0.25 for 5 s | §5.5 |
| Start window (and end window for a ride that began at the end) | along ≤ 50 m (≥ length − 50 m) | §5.5 |
| `stepAlong` projection tolerance | 25 m | §6.1 |
| Forced completion past the manoeuvre | 30 m | §6.2 |
| Jump confirmation | 3 confident fixes; behind: 30 m | §6.2 |
| Official completion gate | along ≥ stepAlong − 5 m | §6.2 |
| Arrival | ≤ 50 m left along the route, coverage ≥ 10 % (loop: ≥ 50 % of all of it) | §7 |
| Coverage gap / direction | ≤ 100 m / s_dir ≥ 0.5 | §7 |
| Wrong way: start / speed | 20 s / ≥ 1 m/s | §8 |
| Wrong way: window | 40 m + mean accuracy (≥ 20 m + accuracy) | §8 |
| Wrong way: enter / other leg / exit | c ≤ −0.5 / c ≥ 0.5 / c ≥ 0.4 on 2 fixes | §8 |
| Wrong way: confirm | along −0.5 × odometer over ≥ 40 m, 2 evaluations ≥ 3 s apart | §8 |
| Wrong way: forward exit | along +30 m | §8 |
| Haptic | ≤ 3 per ride, ≥ 30 s apart | §9.2 |

## 12. Tests and acceptance

### 12.1 Synthetic tests (`Tests/SH2NavTests/RouteMatcherTests.swift`, `WrongWayTests.swift`)
A route builder in local metres (east/north around a reference point) and a simulated rider:
speed profile, Gaussian noise σ, dropouts, and a seeded random generator (SplitMix64), so every run is
repeatable. Each scenario runs at σ = 5, 10 and 20 m with 20 seeds.

| Scenario | Pass when |
| --- | --- |
| Straight 2 km at 20 km/h | Never `off`; along within 4σ of the truth (σ ≤ 10: the GPS error along the route, which no matcher sees); wrong way never confirmed (at σ = 20 m it can be suspected, which only holds the step) |
| Parallel street 15 / 20 / 40 m away for 300 m (σ = 5) | 15 m: stays `on`; 20 m: `off` in at most 2 of 20 runs (correlated noise crosses `L` = 30 m); 40 m: `off` within ≤ 12 s |
| Out-and-back | At the tip and on the way back, along is on the return leg; no wrong way |
| Loop with start = end, 3 turns | Arrival only within the last 75 m (50 m radius + GPS noise), never at the start |
| Loop set off on 300 m (15 %) before its end, on past the start | Never arrives; along back on the loop's start |
| Loop ridden backwards from its start (iPhone course on) | Warned within 200 m; inverted, arrives back at the start |
| Route ridden from its end (loaded the wrong way) | Wrong way confirmed within 150 m |
| Reaching the start backwards along the first stretch, then setting off | No wrong way at all; on route |
| Circuit, 2 laps | Along follows lap 2; arrival only at the end of lap 2 |
| Figure of eight | Through the crossing, keeps the right pass |
| Shortcut skipping 2 manoeuvres | Steps jump forward within 3 confident fixes; never stays `off` |
| Missing a turn by 100 m and coming back to it | Off route meanwhile; no wrong way; arrives; the step never goes back (40 seeds) |
| Start mid-route, riding the right way | Joins within 100 m |
| Start mid-route, crossing at right angles | Doesn't join |
| Stopped 60 s at a light with drift | No `off`, no wrong way, no step change |
| 30 s GPS gap, then 200 m further on | Re-acquires within 3 fixes |
| Riding the route backwards at 18 km/h | Wrong way confirmed within ≤ 15 s and ≤ 75 m (the 45 m movement window, then 2 evaluations 3 s apart) |
| Switchbacks (hairpins every 40 m) | No wrong way |
| Lead-in + GPX sharing a street | No mid-route join while on the lead-in |

### 12.2 Integration (`MatchedEngineTests`)
- Matched mode: exact `stepAlong` for GPX turns, arrival with noise without the pointer, a shortcut
  moving the step on, a loop not ending at its start, the U-turn (once on entry, alone while it lasts, the
  carousel card), "Ignore" (`navOff`, no U-turn), "Invert route" (the ride carries on and arrives at the
  original start, no "Return to route" flash), no inverting a routed destination, no matcher in Compass.
- Classic mode: **every existing test passes unchanged**.

### 12.3 Replay
A `RideReplay` helper rebuilds a `RideEngine` from a trace's header, feeds the fixes, applies the events,
and sums up the ride: off-route episodes, wrong-way episodes, the arrival fix, and the step timeline.

- **Built:** `RideReplay.run` reproduces a recorded ride's commands for both engines (`MatchedEngineTests`),
  and classic traces carry none of the new keys.
- **Still to do:** replay fixtures from road tests in `Tests/SH2NavTests/Fixtures/`, comparing both engines.
- **Privacy:** fixtures committed to the repo must be anonymised (coordinates shifted and rotated) or
  synthetic.

### 12.4 Acceptance
- All of §12.1 passes (20 seeds each; σ = 5 m unless stated, the straight also at 10 and 20 m).
- No confirmed wrong way in 50 seeded out-and-back runs at σ = 8 m, nor on the switchbacks.
- `RouteMatcher.update` under 50 ms per fix on a 22 000-point route in a debug build on CI; the target on
  an iPhone 12-class device in release is ≤ 2 ms (to measure on the road test).
- Road test with "Record rides" on (Settings › Advanced): an urban grid with parallel streets, a loop, an
  out-and-back, a deliberate shortcut, deliberately riding the wrong way and then inverting, a tunnel or
  GPS gap, and stops at lights. Each ride is compared against the classic engine by replay.

### 12.5 Simulation on the demo route
A scripted rider on the app's demo route (`DemoRoute.gpx`, an 8.3 km loop in the Eixample grid), both
engines side by side, 20 seeds each, AR(1) GPS noise (σ 5 m, 14 m in an urban canyon) with the iPhone's
course and speed. Results after the fixes this simulation led to (loop arrival, joining at the start of
a loop, riding a route from its end, the step at a missed corner):

| Scenario | Classic | Matched |
| --- | --- | --- |
| Demo-mode rider (perfect GPS) | Arrives 49 m before the end, 220 ring commands | Identical, command for command |
| Full ride: approach, lights, urban canyon, roundabout, a missed turn, a 35 s GPS gap, a 1.15 km detour on parallel streets, 250 m the wrong way, arrival | Arrives 20/20; 35 false "off route" (urban canyon); no wrong-way warning | Arrives 20/20; 0 false "off route"; real exits flagged 4 s (p90 6 s) after passing 30 m, back on 7 s (p90 9 s) after getting within 15 m; wrong way warned in all 20, after 9–10 s / ~50 m |
| Loop ridden backwards from its start, "Invert route" 3 s after the warning | Off route the whole loop; never arrives | Warned after 23–25 s (~140 m); arrives 20/20 |
| Setting off 150 m before the loop's end | No early arrival | No early arrival (was 20/20 arriving after 19 s) |
| 3.3 km linear route ridden from its end, inverted | Off route; never arrives | Warned after 23 s; arrives 20/20 |

## 13. Out of scope and open questions

- **Rerouting** (Apple routes back to the route): a separate spec. The matcher already supplies what it
  needs: the off-route state, the last confident along and the last manoeuvre passed.
- **Speed-based turn timing:** a separate change to `NavGuidance.stepProgress`.
- **The pointer's heading** under ~12.6 km/h: could use `TravelDirection` later.
- **Turn classification and roundabouts in GPX files.**
- **Open:** whether to send a local notification on wrong way while the phone is locked; whether the
  wrong-way ring sound respects the navigation sound setting (proposed: yes).

## 14. Work units and order

| # | Unit | Files |
| --- | --- | --- |
| MM1 | `routeBearing` and pass helpers | `Ride/RouteGeometry.swift` |
| MM2 | Travel direction | `Ride/TravelDirection.swift` |
| MM3 | Matcher: gate, odometer, candidates, scores, tracking, status, coverage, arrival | `Ride/RouteMatcher.swift` |
| MM4 | `NavStep.routeIndex`, `stepAlong`, `NavGuidance` hooks and step sync | `Navigation/NavSteps.swift`, `RoutedSteps.swift`, `NavGuidance.swift` |
| MM5 | Director: match plumbing, arrival, wrong-way layer, carousel card, sound | `Navigation/NavDirector.swift`, `Commands.swift` |
| MM6 | Wrong-way detector | `Ride/WrongWayDetector.swift` |
| MM7 | `RideEngine`: engine choice, screen from the matcher, `inverted()`, `ignoreWrongWay()` | `Ride/RideEngine.swift` |
| MM8 | Trace fields, `RideReplay`, fixtures | `Ride/RideTrace.swift`, tests |
| MM9 | App: setting, banner and haptics, invert and ignore, Live Activity, strings | `GuidanceController.swift`, `AppSettings.swift`, `AdvancedSettingsView.swift`, `NavigatingView.swift`, `Shared/HaloNavAttributes.swift`, `HaloLiveActivity.swift`, `Localizable.xcstrings` |
| MM10 | Docs: `navigation.md` §6/§8 and `UX_DESIGN.md` §4.3 updated to what was built | `docs/` |

Order: MM1 → MM2 → MM3 (with its tests) → MM4 + MM5 → MM6 → MM7 → MM8 → MM9 → MM10.
