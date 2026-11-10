import Foundation

/// Command payload builders. 1:1 port of `sh2-core/src/commands.mjs`.
///
/// Each builder returns the PLAINTEXT application payload `[service, command, ...args]`.
/// Encryption + bslink framing is handled by `Frame` / `Session`. Command ids come from
/// `CommandsConstants.java` (app) and the nRF/STM firmware dispatch tables; see
/// `docs/protocol/commands.md`.
public enum Commands {

    // MARK: - Service 0 — AUTH (handled by the nRF52)

    /// `{0,0}` getVersions → `[OK, fw(4), bl(4)]`
    public static func getVersions() -> Data { Data([0, 0]) }

    /// `{0,1}` getPeriphPubKey → `[OK, periphPubKey(64), seed(4)]` (plaintext)
    public static func getPeriphPubKey() -> Data { Data([0, 1]) }

    /// `{0,2}` setCentralPubKey + `centralPubKey(64)` → `[OK]` (plaintext request)
    public static func setCentralPubKey(_ pubXY: Data) -> Data { Data([0, 2]) + pubXY } // pubXY: 64 B

    /// `{0,3}` authenticate + password → `[OK]`/`[FAIL]` (encrypted)
    public static func authenticate(_ password: Data) -> Data { Data([0, 3]) + password }

    /// `{0,4}` setPassword + password → `[OK]` (encrypted, requires permission)
    public static func setPassword(_ password: Data) -> Data { Data([0, 4]) + password }

    /// `{0,5}` getSerial(idx) → serial
    public static func getSerial(_ idx: UInt8 = 0) -> Data { Data([0, 5, idx]) }

    /// `{0,6}` getSeed → `[OK, seed(4)]` (plaintext — reset-challenge recovery path)
    public static func getSeed() -> Data { Data([0, 6]) }

    /// `{0,7}` resetPassword + `SHA256(seed‖salt)`(32) → `[OK]`/`[FAIL]` (plaintext)
    public static func resetPassword(_ challenge32: Data) -> Data { Data([0, 7]) + challenge32 }

    // MARK: - Service 1 — UI / display OLED + LED ring (STM32)

    public enum LightMode: UInt8, Sendable {
        case normal = 0
        case blinking = 1
    }

    /// `{1,4}` front light (ring): `[1,4, on?1:0, external?1:0]`
    public static func frontLight(on: Bool, external: Bool = false) -> Data {
        Data([1, 4, on ? 1 : 0, external ? 1 : 0])
    }

    /// `{1,16}` front light settings:
    /// `[1,16, mode, brightness, blinkingLocked?1:0, silenceRocker?1:0]`
    public static func frontLightSettings(
        mode: LightMode,
        brightness: UInt8,
        blinkingLocked: Bool = false,
        silenceRocker: Bool = false
    ) -> Data {
        Data([1, 16, mode.rawValue, brightness, blinkingLocked ? 1 : 0, silenceRocker ? 1 : 0])
    }

    /// `{1,14}` animOff — turn off the current animation
    public static func animOff() -> Data { Data([1, 14]) }

    /// `{1,15}` setBrightness — global brightness
    public static func setBrightness(_ v: UInt8) -> Data { Data([1, 15, v]) }

    /// A ring colour in the firmware's HSL byte form (each 0…255). Port of `SHColour`.
    public struct Colour: Sendable {
        public var hue: UInt8, saturation: UInt8, lightness: UInt8
        public init(hue: UInt8, saturation: UInt8, lightness: UInt8) {
            self.hue = hue; self.saturation = saturation; self.lightness = lightness
        }
        public static let teal = Colour(hue: 128, saturation: 255, lightness: 128)
        public static let white = Colour(hue: 0, saturation: 0, lightness: 255)
    }

    /// `{1,28}` clock — show the time on the LED ring. Port of `ClockCommandPayload.getBytes()`:
    /// `[hour, hColour(3), minute, mColour(3), dur>>8, dur, fade, intro, pulse, is24h]`.
    public static func showClock(hour: UInt8, minute: UInt8,
                                 hourColour: Colour = .teal, minuteColour: Colour = .white,
                                 durationMs: UInt16 = 5000,
                                 fade: Bool = true, intro: Bool = false,
                                 pulse: Bool = false, is24h: Bool = true) -> Data {
        Data([
            1, 28,
            hour, hourColour.hue, hourColour.saturation, hourColour.lightness,
            minute, minuteColour.hue, minuteColour.saturation, minuteColour.lightness,
            UInt8((durationMs >> 8) & 0xff), UInt8(durationMs & 0xff),
            fade ? 1 : 0, intro ? 1 : 0, pulse ? 1 : 0, is24h ? 1 : 0,
        ])
    }

    /// `{1,18}` speedometer. Port of `SpeedometerCommandPayload.getBytes()`:
    /// `[percentage, speed, metric?0:1]`.
    public static func showSpeedometer(percentage: UInt8, speed: UInt8, metric: Bool = true) -> Data {
        Data([1, 18, percentage, speed, metric ? 0 : 1])
    }

    /// `{1,31}` show the charger / state-of-charge animation on the ring.
    public static func showStateOfCharge() -> Data { Data([1, 31]) }

    // MARK: Service 1 — display widgets & assistant (M1)
    //
    // Byte layouts reverse engineered from the official app's `UICommandsController` + `*CommandPayload` classes.
    // `{service,cmd}` ids from `CommandsConstants.java`.

    /// `{1,0}` logo — show the SmartHalo logo animation.
    public static func logo() -> Data { Data([1, 0]) }

    /// `{1,25}` demo — run the built-in demo animation. // TODO: the app appends extra bytes.
    public static func demo() -> Data { Data([1, 25]) }

    /// `{1,11}` compass — point the ring to a heading (0…359°) in a colour.
    /// `ui_compass`: `[1,11, hue, sat, light, heading>>8, heading]`.
    public static func compass(heading: UInt16, colour: Colour = .teal) -> Data {
        Data([1, 11, colour.hue, colour.saturation, colour.lightness,
              UInt8((heading >> 8) & 0xff), UInt8(heading & 0xff)])
    }
    /// `{1,12}` compass off.
    public static func compassOff() -> Data { Data([1, 12]) }

    /// `{1,5}` progress — goal progress ring. Port of `ProgressCommandPayload.getBytes()` WITHOUT the
    /// optional trailing text: `[c1(3), c2(3), period>>8, period, percentage, fitness?1:0]`.
    public static func progress(percentage: UInt8, periodMs: UInt16 = 2000,
                                firstColour: Colour = .teal, secondColour: Colour = .white,
                                fitnessMode: Bool = false) -> Data {
        Data([1, 5,
              firstColour.hue, firstColour.saturation, firstColour.lightness,
              secondColour.hue, secondColour.saturation, secondColour.lightness,
              UInt8((periodMs >> 8) & 0xff), UInt8(periodMs & 0xff),
              percentage, fitnessMode ? 1 : 0])
        // TODO: trailing formatted description string (CommandsHelper.getFormattedDescription).
    }
    /// `{1,6}` progress off.
    public static func progressOff() -> Data { Data([1, 6]) }

    /// `{1,9}` heartbeat — pulsing ring. Port of `ui_hb`:
    /// `[c1(3), c2(3), a>>8,a, b>>8,b, c>>8,c, d>>8,d]` (four 16-bit timing params).
    public static func heartbeat(firstColour: Colour = .teal, secondColour: Colour = .white,
                                 a: UInt16 = 1000, b: UInt16 = 1000, c: UInt16 = 60, d: UInt16 = 0) -> Data {
        func hl(_ v: UInt16) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
        return Data([1, 9,
              firstColour.hue, firstColour.saturation, firstColour.lightness,
              secondColour.hue, secondColour.saturation, secondColour.lightness]
              + hl(a) + hl(b) + hl(c) + hl(d))
    }
    /// `{1,10}` heartbeat off.
    public static func heartbeatOff() -> Data { Data([1, 10]) }

    /// `{1,21}` low-battery animation. `ui_lowbat`: `[1,21, 0]`.
    public static func lowBattery() -> Data { Data([1, 21, 0]) }

    /// `{1,30}` toggle the external (handlebar) front light. `[1,30, on?1:0]`.
    public static func frontExternalToggle(on: Bool) -> Data { Data([1, 30, on ? 1 : 0]) }

    /// `{1,19}` speedometer off.
    public static func speedometerOff() -> Data { Data([1, 19]) }

    /// `{1,29}` clock off.
    public static func clockOff() -> Data { Data([1, 29]) }

    /// `{1,26}` speedometer intro animation (no args).
    public static func speedometerIntro() -> Data { Data([1, 26]) }

    /// `{1,27}` fitness intro. Port of `experimental_fitness_intro`:
    /// `[1,27, c1(3), c2(3), value>>8, value]`.
    public static func fitnessIntro(colour: Colour = .teal, secondColour: Colour = .white,
                                    value: UInt16 = 0) -> Data {
        Data([1, 27, colour.hue, colour.saturation, colour.lightness,
              secondColour.hue, secondColour.saturation, secondColour.lightness,
              UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    /// `{1,32}` turn-by-turn intro: OLED "navigation" art + `title` for 3 s, ring intro animation.
    /// `[1,32, mode, title… 0]`; the official app always sends mode 2 (TriplePulse).
    public static func turnByTurnIntro(title: String, mode: UInt8 = 2) -> Data {
        Data([1, 32, mode] + navText(title, header: 3))
    }

    /// `{1,33}` navigation pointer with intro. Port of `ui_pointer_intro`:
    /// `[1,33, c(3), heading>>8, heading, exit]`.
    public static func pointerWithIntro(heading: UInt16, exit: UInt8 = 0, colour: Colour = .teal) -> Data {
        Data([1, 33, colour.hue, colour.saturation, colour.lightness,
              UInt8((heading >> 8) & 0xff), UInt8(heading & 0xff), exit])
    }

    /// `{1,20}` roundabout. // TODO: full payload (exit + colours + text); minimal trigger here.
    public static func roundabout(exit: UInt8 = 0) -> Data { Data([1, 20, exit]) }
    /// `{1,34}` roundabout (OLED). // TODO: params.
    public static func roundaboutOled(exit: UInt8 = 0) -> Data { Data([1, 34, exit]) }

    /// The ring's carousel cards (bit `rawValue` of the carousel mask; `RideTask.h` order).
    public enum CarouselCard: UInt8, CaseIterable, Sendable {
        case navigation = 0, goal, distance, time, speed, calories, clock, avgSpeed, co2, battery
        public var bit: UInt16 { 1 << UInt16(rawValue) }
    }

    /// Carousel header `[1,35, card, mask (uint32 LE)]`. A frame with only the header updates the
    /// mask; with a payload it is that card's content (`updateCarouselMetricData`, RideTask.c).
    static func carouselHeader(_ card: CarouselCard, mask: UInt16) -> [UInt8] {
        [1, 35, card.rawValue, UInt8(mask & 0xff), UInt8(mask >> 8), 0, 0]
    }

    /// `{1,35}` set which cards the ring cycles through, without moving it.
    public static func carouselMask(_ mask: UInt16) -> Data {
        Data(carouselHeader(.navigation, mask: mask))
    }

    /// Clock card. Port of `AssistantCommandsController.getClockPayload()`: hour in white
    /// (`CLOCK_COLOURS`), minute in `ASSISTANT_COLOURS`, fade + intro + pulse; the ring ignores the
    /// duration on this card.
    public static func carouselClock(mask: UInt16, hour: UInt8, minute: UInt8, is24h: Bool) -> Data {
        Data(carouselHeader(.clock, mask: mask)
             + [hour, 0, 0, 220, minute, 143, 219, 198, 0x13, 0x88, 1, 1, 1, is24h ? 1 : 0])
    }

    /// Battery card: the ring draws its own state of charge (the official app sends no payload).
    public static func carouselBattery(mask: UInt16) -> Data { Data(carouselHeader(.battery, mask: mask)) }

    /// Speed card. Port of `CarouselController` (speed in km/h): under 5 km/h → 0 (the snail),
    /// else gauge `speed / 40 × 100 %`; `[percentage, speed, unit]`, unit 0 = km/h, 1 = mph.
    public static func carouselSpeed(mask: UInt16, kmh: Double, metric: Bool = true) -> Data {
        let moving = kmh >= 5
        let pct = moving ? UInt8(clamping: NavMath.trunc(min(100, (kmh / 40 * 100).rounded()))) : 0
        let shown = metric ? kmh : kmh / 1.609344
        let speed = moving ? UInt8(clamping: NavMath.trunc(shown.rounded())) : 0
        return Data(carouselHeader(.speed, mask: mask) + [pct, speed, metric ? 0 : 1])
    }

    /// Distance card: ride distance (4 bytes, bit 31 = imperial; the ring formats m/km or ft/mi).
    public static func carouselDistance(mask: UInt16, metres: Int, metric: Bool = true) -> Data {
        Data(carouselHeader(.distance, mask: mask) + metric4(metres, metric: metric))
    }

    /// Ride-time card: elapsed seconds, uint16 BE (the ring caps it at 18 h 12 min).
    public static func carouselTime(mask: UInt16, seconds: Int) -> Data {
        let v = UInt16(clamping: max(0, seconds))
        return Data(carouselHeader(.time, mask: mask) + [UInt8(v >> 8), UInt8(v & 0xff)])
    }

    /// Average-speed card: average and current speed in metres (or feet) per hour, then the gauge
    /// colours for slower / average / faster than the average.
    public static func carouselAvgSpeed(mask: UInt16, averageKmh: Double, currentKmh: Double,
                                        metric: Bool = true) -> Data {
        let lower = NavColour.caution, average = Colour.white, higher = NavColour.turn
        return Data(carouselHeader(.avgSpeed, mask: mask)
                    + metric4(NavMath.trunc((averageKmh * 1000).rounded()), metric: metric)
                    + metric4(NavMath.trunc((currentKmh * 1000).rounded()), metric: metric)
                    + [lower.hue, lower.saturation, lower.lightness,
                       average.hue, average.saturation, average.lightness,
                       higher.hue, higher.saturation, higher.lightness])
    }

    /// `{1,36}` carousel position — jump to a widget index. `[1,36, index]`.
    public static func carouselPosition(_ index: UInt8) -> Data { Data([1, 36, index]) }
    /// `{1,36}` carousel position + card mask (the firmware only updates the mask with all 5 bytes):
    /// `[1,36, index, mask lo, mask hi, 0, 0]`. Mask bits: 0 navigation, 1 goal, 2 distance, 3 time,
    /// 4 speed, 5 calories, 6 clock, 7 avg speed, 8 CO2, 9 battery.
    public static func carouselPosition(_ index: UInt8, mask: UInt16) -> Data {
        Data([1, 36, index, UInt8(mask & 0xff), UInt8(mask >> 8), 0, 0])
    }

    // MARK: Service 1 — navigation / guidance
    //
    // Reverse engineered from the official app (`NavigationCommandsController` → SDK `UICommandsController`),
    // checked against the STM firmware handlers (`RideTask.c`). See docs/protocol/navigation.md.

    /// Navigation colours of the official app (`DirectionHelper`, `DeviceConstants.Navigation`).
    public enum NavColour {
        /// Turn arrows, destination (`TURN_*`, "navigation green").
        public static let turn = Colour(hue: 67, saturation: 255, lightness: 255)
        /// Caution transportation mode (`EXCEPTION_*`).
        public static let caution = Colour(hue: 38, saturation: 234, lightness: 249)
        /// U-turn, wrong roundabout exits (`WARNING_*`).
        public static let warning = Colour(hue: 253, saturation: 237, lightness: 255)
        /// Pointer back to a GPX route (`OFF_PATH_COMPASS_*`).
        public static let offPath = Colour(hue: 30, saturation: 255, lightness: 255)
        /// `getNavColourFromProgressForSmartHalo`: hue 17 (far) … 67 (there), progress 0…100.
        public static func progress(_ p: Int) -> Colour {
            Colour(hue: UInt8(clamping: 17 + Int(Float(p) / 100 * 50)), saturation: 255, lightness: 255)
        }
    }

    /// Distance field: 4 bytes big-endian, bit 31 set = imperial. Port of
    /// `CommandsHelper.getFormatted4ByteMetric` plus the app's unit conversion: metres, or feet
    /// (`metersToFeet`: rounded to 0.1 ft, then to an integer) when `metric` is false; the ring
    /// switches to miles itself. Negative distances (the app's "distance − 50") are clamped to 0:
    /// sent raw they would set the imperial bit.
    static func metric4(_ metres: Int, metric: Bool) -> [UInt8] {
        let value = metric ? metres : Int((Double(metres) * 3.2808399 * 10).rounded() / 10 + 0.5)
        let v = UInt32(truncatingIfNeeded: max(0, value)) & 0x7fff_ffff
        return [UInt8((v >> 24) & 0xff) | (metric ? 0 : 0x80), UInt8((v >> 16) & 0xff),
                UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    /// Signed angle, degrees (ring frame: 0 = ahead, + = clockwise/right), int16 big-endian.
    static func angle16(_ degrees: Int) -> [UInt8] {
        let v = UInt16(bitPattern: Int16(clamping: degrees))
        return [UInt8(v >> 8), UInt8(v & 0xff)]
    }

    /// Text field: ISO-8859-1, NUL-terminated (`CommandsHelper.getFormattedDescription`, whole
    /// payload ≤ 80 bytes). Also capped at 29 characters: the firmware keeps 30 bytes, and its
    /// intro handler overflows its buffer with longer titles.
    static func navText(_ text: String, header: Int) -> [UInt8] {
        let limit = min(80 - header - 1, 29)
        let latin1 = plainPunctuation(text).unicodeScalars.prefix(limit).map {
            $0.value <= 0xff ? UInt8($0.value) : UInt8(ascii: "?")
        }
        return latin1 + [0]
    }

    /// Addition: Latin-1 for the typographic punctuation in Apple's directions, which would
    /// show as "?" ("Carrer d’Aragó"). The OLED's font covers all of Latin-1.
    static func plainPunctuation(_ text: String) -> String {
        var plain = ""
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{2032}": plain += "'"
            case "\u{201C}", "\u{201D}", "\u{201E}": plain += "\""
            case "\u{2010}", "\u{2011}", "\u{2013}", "\u{2014}", "\u{2212}": plain += "-"
            case "\u{2026}": plain += "..."
            default: plain.unicodeScalars.append(scalar)
            }
        }
        return plain
    }

    /// `{1,3}` navigation off.
    public static func navOff() -> Data { Data([1, 3]) }
    /// `{1,2}` navigation reroute (white spiral on the ring).
    public static func navReroute() -> Data { Data([1, 2]) }

    /// `{1,17}` nav angle (quick): this turn's arc + the following turn's arc, with the distance and
    /// instruction on the OLED. Port of `ui_nav_angle_quick`:
    /// `[1,17, c(3), angle(2), progress|sameTurn<<7, nc(3), nextAngle(2), nextProgress] + D(4) + ND(4) + text`.
    /// `sameTurn` (bit 7) keeps the arc from re-animating while its angle changes (turning onto a GPX
    /// route). `nextProgress` 0 = draw only this turn.
    public static func navAngle(colour: Colour, angle: Int, progress: Int, sameTurn: Bool = false,
                                nextColour: Colour, nextAngle: Int, nextProgress: Int,
                                distance: Int, nextDistance: Int, text: String,
                                metric: Bool = true) -> Data {
        var bytes: [UInt8] = [1, 17, colour.hue, colour.saturation, colour.lightness]
        bytes += angle16(angle)
        bytes.append(UInt8(truncatingIfNeeded: progress + (sameTurn ? 128 : 0)))   // Java (byte) cast
        bytes += [nextColour.hue, nextColour.saturation, nextColour.lightness]
        bytes += angle16(nextAngle)
        bytes.append(UInt8(truncatingIfNeeded: nextProgress))
        bytes += metric4(distance, metric: metric)
        bytes += metric4(nextDistance, metric: metric)
        bytes += navText(text, header: 22)
        return Data(bytes)
    }

    /// `{1,1}` nav — legacy glyph: step type 0 = destination (full ring), 8 = U-turn. Port of `ui_nav`:
    /// `[1,1, c(3), stepType, progress] + D(4) + text`.
    public static func nav(stepType: UInt8, progress: Int, distance: Int, text: String,
                           metric: Bool = true, colour: Colour = NavColour.turn) -> Data {
        Data([1, 1, colour.hue, colour.saturation, colour.lightness, stepType, UInt8(truncatingIfNeeded: progress)]
             + metric4(distance, metric: metric) + navText(text, header: 11))
    }

    /// `{1,22}` nav pointer — the ring points `angle` degrees off the rider's direction of travel.
    /// Port of `ui_nav_pointer`: `[1,22, c(3), angle(2)] + D(4) + text`. The ring only draws it once
    /// the bike has moved (accelerometer); the OLED shows text + distance.
    public static func navPointer(angle: Int, distance: Int, text: String,
                                  metric: Bool = true, colour: Colour) -> Data {
        Data([1, 22, colour.hue, colour.saturation, colour.lightness] + angle16(angle)
             + metric4(distance, metric: metric) + navText(text, header: 11))
    }
    /// `{1,23}` nav pointer off.
    public static func navPointerOff() -> Data { Data([1, 23]) }
    /// `{1,24}` nav pointer standby — direction unknown yet: rotating pointer, OLED "Ride to
    /// calibrate". Port of `ui_pointer_standby`: `[1,24, c(3)] + D(4) + text`.
    public static func navPointerStandby(distance: Int, text: String, metric: Bool = true,
                                         colour: Colour) -> Data {
        Data([1, 24, colour.hue, colour.saturation, colour.lightness]
             + metric4(distance, metric: metric) + navText(text, header: 9))
    }

    /// `{1,35}` carousel with the navigation card (`CarouselController.updateNavigationCard`): sent
    /// when the ring shows its Navigation card. `[1,35, 0, mask lo, mask hi, 0, 0] + D(4) + angle(2)
    /// + white (0,0,220) + text`; without guidance only the 7-byte header.
    public static func carouselNavigationCard(mask: UInt16, distance: Int? = nil, angle: Int = 0,
                                              text: String = "", metric: Bool = true) -> Data {
        var bytes: [UInt8] = [1, 35, 0, UInt8(mask & 0xff), UInt8(mask >> 8), 0, 0]
        if let distance {
            bytes += metric4(distance, metric: metric)
            bytes += angle16(angle)
            bytes += [0, 0, 220]
            bytes += navText(text, header: 16)
        }
        return Data(bytes)
    }

    /// Icon the firmware draws for a `{1,7}` notification (`RideTask.c`, `showNotification`).
    public enum NotificationType: UInt8 {
        case call = 0
        /// The storm icon.
        case weather = 32
        case error = 69
    }

    /// `{1,7}` notification: `[1,7, c1(3), c2(3), fadeIn(2), on(2), fadeOut(2), off(2), repeat, type]
    /// + text`. The firmware only reads c1, repeat, type and text: the whole ring pulses for
    /// `(1 + repeat) × 500 + 700` ms, and the ring's turn guidance waits twice `700 + 500 × repeat` ms
    /// or until `{1,8}`. That duration is a `uint16_t`, so keep repeat ≤ 129.
    public static func notification(type: NotificationType, colour: [UInt8], timing: [UInt16],
                                    repeat: UInt8, text: String) -> Data {
        let dimmed = Array(colour.prefix(2)) + [0]
        let times = timing.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
        let header: [UInt8] = [1, 7] + colour + dimmed + times + [`repeat`, type.rawValue]
        return Data(header + navText(text, header: header.count))
    }

    /// `{1,8}` notification off: frees the turn guidance straight away. The OLED image stays until
    /// its own time runs out (`notifyOff` doesn't touch it).
    public static func notificationOff() -> Data { Data([1, 8]) }

    /// The official app's error animation (`playErrorAnimation`): red pulses and a question mark.
    public static func errorNotification(text: String = "An error occurred") -> Data {
        notification(type: .error, colour: [253, 237, 255], timing: [200, 50, 100, 10], repeat: 3, text: text)
    }

    /// The official app's incoming-call pulse (`AssistantController.ringCall`) with a call icon,
    /// limited to about 30 s: its repeat of 255 overflows the firmware's duration and would hold the
    /// turn guidance for about 125 s if the app were suspended before sending `{1,8}`.
    public static func incomingCall(text: String) -> Data {
        notification(type: .call, colour: [143, 219, 198], timing: [100, 256, 100, 0], repeat: 60, text: text)
    }

    /// Rain warning: blue pulses and the storm icon for about 6 s. The firmware has the icon, but the
    /// official app never used it.
    public static func rainAlert(text: String) -> Data {
        notification(type: .weather, colour: [170, 220, 255], timing: [200, 50, 100, 10], repeat: 10, text: text)
    }

    // MARK: - Service 2 — Sound (STM32 piezo)

    public static func soundPlay() -> Data { Data([2, 0]) }
    /// `{2,0}` play a track: `[2,0, volume ≤ 100, repeat, (freq(2) ms(2))…]` (plays repeat + 1 times).
    public static func soundPlay(volume: UInt8, repeat: UInt8 = 0, track: [UInt8]) -> Data {
        Data([2, 0, min(100, volume), `repeat`] + track)
    }

    /// Navigation tracks of the official app (`SHSounds`): `freq Hz(2) duration ms(2)` per note.
    public enum NavSound {
        public static let progress: [UInt8] = [0x01, 0x25, 0x00, 0x40, 0x01, 0x87, 0x00, 0x56]
        /// Silent in the original (frequency 0, 106 ms).
        public static let turnNow: [UInt8] = [0x00, 0x00, 0x00, 0x6a]
        public static let destination: [UInt8] = [0x01, 0x05, 0x00, 0x51, 0x01, 0x49, 0x00, 0x6b,
                                                  0x01, 0x87, 0x00, 0x69, 0x02, 0x0b, 0x00, 0xc3]
        public static let info: [UInt8] = [0x01, 0x05, 0x00, 0x58, 0x01, 0x5d, 0x00, 0x63, 0x01, 0x49, 0x00, 0x39]
        /// Addition: wrong way (the official set has no warning): 440 Hz for 150 ms, then 330 Hz for
        /// 250 ms.
        public static let wrongWay: [UInt8] = [0x01, 0xb8, 0x00, 0x96, 0x01, 0x4a, 0x00, 0xfa]
    }
    public static func soundStop() -> Data { Data([2, 1]) }
    /// `{2,2}` touch sounds. `[2,2, volume ≤ 100, on?1:0]` (`SoundsCommandsController.toggleTouchSounds`;
    /// the firmware rejects a shorter payload). The official default volume is 40.
    public static func soundTouch(on: Bool, volume: UInt8 = 40) -> Data { Data([2, 2, min(100, volume), on ? 1 : 0]) }

    /// The official app's horn (`SHSounds.horn_sound`), played at volume 100 by the "horn" tap code.
    public static let hornTrack: [UInt8] = [0x01, 0xd2, 0x00, 0xfa, 0x00, 0x00, 0x00, 0x64,
                                            0x01, 0xd2, 0x01, 0xf4, 0x00, 0x00, 0x00, 0x00]

    /// The official app's ringtone (`SHSounds.call_sound`): four 466/369 Hz pairs, then 1 s of silence.
    public static let callTrack: [UInt8] = Array(repeating: [0x01, 0xd2, 0x00, 0x50, 0x01, 0x71, 0x00, 0x50],
                                                 count: 4).flatMap { $0 } + [0x00, 0x00, 0x03, 0xe8]
    /// `callTrack` for about 31 s (19 × 1.64 s), the length of the `incomingCall` pulse.
    public static func callSound() -> Data { soundPlay(volume: 50, repeat: 18, track: callTrack) }

    /// `{1,37}` touch onboarding animation. // TODO: params.
    public static func touchOnboarding() -> Data { Data([1, 37]) }

    // MARK: - Service 3 — Alarm / system (STM32)

    /// `{3,0}` report (getAlarmReport) → AlarmReport
    public static func alarmReport() -> Data { Data([3, 0]) }

    /// `{3,1}` getSeed (alarm)
    public static func alarmGetSeed() -> Data { Data([3, 1]) }

    /// `{3,3}` configure the alarm — how the official app arms and disarms it (`AlarmController.
    /// updateAlarmState` → `AlarmCommandsController.configureAlarm`; it never sends `{3,2}`):
    /// `[3,3, seed(4), tapCode, tapLength, armed?1:0, vigilant?1:0]`. The firmware stores it
    /// (`AlarmConfig` file) and, with `armed`, arms itself once the phone disconnects and the Halo
    /// isn't charging; reconnecting disarms it again (`AlarmTask.c`). `tapCode` bit i = tap i was
    /// long; the code arms/disarms it on the Halo while no phone is connected.
    public static func alarmConfigure(seed: Data, tapCode: UInt8, tapLength: UInt8,
                                      armed: Bool, vigilant: Bool) -> Data {
        var d = Data([3, 3]); d.append(seed.prefix(4))
        d.append(contentsOf: [tapCode, tapLength, armed ? 1 : 0, vigilant ? 1 : 0])
        return d
    }

    // MARK: - Service 4 — Device / DFU (STM32 + bootloader)

    public static func enterBootloader() -> Data { Data([4, 0]) }
    public static func getState() -> Data { Data([4, 1]) }
    public static func setName(_ name: String) -> Data { Data([4, 2]) + Data(name.utf8) }
    public static func shutdown() -> Data { Data([4, 4]) }

    /// `{4,3}` compass calibrate.
    public static func compassCalibrate() -> Data { Data([4, 3]) }

    /// `{4,6}` localization — set the device clock + language. Port of `updateDeviceTime`:
    /// `[4,6] + <unix seconds, 8-byte little-endian> + language(ASCII)`.
    /// (`CommandsHelper.getBytesFromLong(t, true)` builds 8 bytes big-endian then reverses → LE.)
    public static func localization(unixSeconds: UInt64, language: String) -> Data {
        var d = Data([4, 6])
        var v = unixSeconds
        for _ in 0..<8 { d.append(UInt8(v & 0xff)); v >>= 8 }   // little-endian
        d.append(Data(language.prefix(2).utf8))
        return d
    }
}
