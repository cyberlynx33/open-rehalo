import XCTest
@testable import SH2Nav

/// Guards the command byte layouts against the reverse engineered official app (CommandsConstants + the
/// carousel payload classes).
final class CommandsTests: XCTestCase {

    func testCoreCommandIds() {
        XCTAssertEqual([UInt8](Commands.getVersions()), [0, 0])
        XCTAssertEqual([UInt8](Commands.getSeed()), [0, 6])
        XCTAssertEqual([UInt8](Commands.frontLight(on: true)), [1, 4, 1, 0])
        XCTAssertEqual([UInt8](Commands.setName("AB")), [4, 2, 0x41, 0x42])
    }

    func testShowClockLayout() {
        // Port of ClockCommandPayload.getBytes(): [hour, hColour(3), minute, mColour(3),
        // dur>>8, dur, fade, intro, pulse, is24h], prefixed with cmd_clock {1,28}.
        let d = [UInt8](Commands.showClock(
            hour: 9, minute: 41,
            hourColour: .init(hue: 128, saturation: 255, lightness: 128),
            minuteColour: .init(hue: 0, saturation: 0, lightness: 255),
            durationMs: 5000, fade: true, intro: false, pulse: false, is24h: true))
        XCTAssertEqual(d, [1, 28, 9, 128, 255, 128, 41, 0, 0, 255, 0x13, 0x88, 1, 0, 0, 1])
    }

    func testShowSpeedometerLayout() {
        // SpeedometerCommandPayload.getBytes(): [percentage, speed, metric?0:1], prefix {1,18}.
        XCTAssertEqual([UInt8](Commands.showSpeedometer(percentage: 60, speed: 24, metric: true)), [1, 18, 60, 24, 0])
        XCTAssertEqual([UInt8](Commands.showSpeedometer(percentage: 60, speed: 24, metric: false)), [1, 18, 60, 24, 1])
    }

    func testDisplayWidgetLayouts() {
        let teal = Commands.Colour.teal, white = Commands.Colour.white
        XCTAssertEqual([UInt8](Commands.logo()), [1, 0])
        XCTAssertEqual([UInt8](Commands.demo()), [1, 25])
        XCTAssertEqual([UInt8](Commands.compassOff()), [1, 12])
        XCTAssertEqual([UInt8](Commands.progressOff()), [1, 6])
        XCTAssertEqual([UInt8](Commands.heartbeatOff()), [1, 10])
        XCTAssertEqual([UInt8](Commands.speedometerOff()), [1, 19])
        XCTAssertEqual([UInt8](Commands.clockOff()), [1, 29])
        XCTAssertEqual([UInt8](Commands.speedometerIntro()), [1, 26])
        // Official start sequence: intro (mode 2 = TriplePulse) + carousel jump to Navigation.
        XCTAssertEqual([UInt8](Commands.turnByTurnIntro(title: "Home")), [1, 32, 2, 0x48, 0x6f, 0x6d, 0x65, 0])
        XCTAssertEqual([UInt8](Commands.carouselPosition(0, mask: 0x02fd)), [1, 36, 0, 0xfd, 0x02, 0, 0])
        XCTAssertEqual([UInt8](Commands.lowBattery()), [1, 21, 0])
        XCTAssertEqual([UInt8](Commands.frontExternalToggle(on: true)), [1, 30, 1])

        // ui_compass: [1,11, hue,sat,light, heading>>8, heading]
        XCTAssertEqual([UInt8](Commands.compass(heading: 300, colour: teal)),
                       [1, 11, 128, 255, 128, 0x01, 0x2c])

        // ProgressCommandPayload: [c1(3), c2(3), period>>8, period, percentage, fitness?1:0]
        XCTAssertEqual([UInt8](Commands.progress(percentage: 75, periodMs: 2000,
                                                 firstColour: teal, secondColour: white, fitnessMode: false)),
                       [1, 5, 128, 255, 128, 0, 0, 255, 0x07, 0xd0, 75, 0])

        // ui_hb: [c1(3), c2(3), a>>8,a, b>>8,b, c>>8,c, d>>8,d]
        XCTAssertEqual([UInt8](Commands.heartbeat(firstColour: teal, secondColour: white,
                                                  a: 1000, b: 1000, c: 60, d: 0)),
                       [1, 9, 128, 255, 128, 0, 0, 255, 0x03, 0xe8, 0x03, 0xe8, 0x00, 0x3c, 0x00, 0x00])

        // fitness intro: [1,27, c1(3), c2(3), value>>8, value]
        XCTAssertEqual([UInt8](Commands.fitnessIntro(colour: teal, secondColour: white, value: 0)),
                       [1, 27, 128, 255, 128, 0, 0, 255, 0, 0])

        // pointer with intro: [1,33, c(3), heading>>8, heading, exit]
        XCTAssertEqual([UInt8](Commands.pointerWithIntro(heading: 90, exit: 2, colour: teal)),
                       [1, 33, 128, 255, 128, 0x00, 0x5a, 2])

        XCTAssertEqual([UInt8](Commands.carouselPosition(1)), [1, 36, 1])
    }

    /// Carousel cards: `[1,35, card, mask uint32 LE]` + the card payload (`updateCarouselMetricData`).
    func testCarouselCards() {
        let mask: UInt16 = 0x02dc   // distance, time, speed, clock, avg, battery
        XCTAssertEqual([UInt8](Commands.carouselMask(mask)), [1, 35, 0, 0xdc, 0x02, 0, 0])
        XCTAssertEqual([UInt8](Commands.carouselBattery(mask: mask)), [1, 35, 9, 0xdc, 0x02, 0, 0])
        XCTAssertEqual([UInt8](Commands.carouselClock(mask: mask, hour: 18, minute: 42, is24h: true)),
                       [1, 35, 6, 0xdc, 0x02, 0, 0, 18, 0, 0, 220, 42, 143, 219, 198, 0x13, 0x88, 1, 1, 1, 1])
        // speed: under 5 km/h → snail (0, 0); 24 km/h → 60 %
        XCTAssertEqual([UInt8](Commands.carouselSpeed(mask: mask, kmh: 3)), [1, 35, 4, 0xdc, 0x02, 0, 0, 0, 0, 0])
        XCTAssertEqual([UInt8](Commands.carouselSpeed(mask: mask, kmh: 24)), [1, 35, 4, 0xdc, 0x02, 0, 0, 60, 24, 0])
        XCTAssertEqual([UInt8](Commands.carouselSpeed(mask: mask, kmh: 80)).suffix(3), [100, 80, 0])
        XCTAssertEqual([UInt8](Commands.carouselDistance(mask: mask, metres: 12_400)),
                       [1, 35, 2, 0xdc, 0x02, 0, 0, 0x00, 0x00, 0x30, 0x70])
        XCTAssertEqual([UInt8](Commands.carouselTime(mask: mask, seconds: 2530)), [1, 35, 3, 0xdc, 0x02, 0, 0, 0x09, 0xe2])
        XCTAssertEqual([UInt8](Commands.carouselTime(mask: mask, seconds: 100_000)).suffix(2), [0xff, 0xff])
        let avg = [UInt8](Commands.carouselAvgSpeed(mask: mask, averageKmh: 21.8, currentKmh: 25))
        XCTAssertEqual(Array(avg.prefix(15)), [1, 35, 7, 0xdc, 0x02, 0, 0, 0x00, 0x00, 0x55, 0x28, 0x00, 0x00, 0x61, 0xa8])
        XCTAssertEqual(avg.count, 24)
    }

    /// A speed that isn't a number, or is absurd, makes a harmless card rather than a trap in `Int(_:)`.
    func testCarouselSpeedsSurviveBadNumbers() {
        let mask: UInt16 = 0x02dc
        XCTAssertEqual([UInt8](Commands.carouselSpeed(mask: mask, kmh: .nan)).suffix(3), [0, 0, 0])
        XCTAssertEqual([UInt8](Commands.carouselSpeed(mask: mask, kmh: 1e30)).suffix(3), [100, 255, 0])
        let avg = [UInt8](Commands.carouselAvgSpeed(mask: mask, averageKmh: .nan, currentKmh: .infinity))
        XCTAssertEqual(Array(avg[7..<15]), [0, 0, 0, 0, 0x7f, 0xff, 0xff, 0xff])
    }

    func testAlarmSoundTouchLayouts() {
        let seed = Data([0xAA, 0xBB, 0xCC, 0xDD])
        // configureAlarm (official): [3,3, seed(4), tapCode, tapLength, armed, vigilant]
        // tap code "SLL" → bits 1 and 2 → 0b110
        XCTAssertEqual([UInt8](Commands.alarmConfigure(seed: seed, tapCode: 0b110, tapLength: 3, armed: true, vigilant: false)),
                       [3, 3, 0xAA, 0xBB, 0xCC, 0xDD, 6, 3, 1, 0])
        XCTAssertEqual([UInt8](Commands.alarmConfigure(seed: seed, tapCode: 0b110, tapLength: 3, armed: false, vigilant: true)),
                       [3, 3, 0xAA, 0xBB, 0xCC, 0xDD, 6, 3, 0, 1])
        // sound + touch
        XCTAssertEqual([UInt8](Commands.soundPlay()), [2, 0])
        XCTAssertEqual([UInt8](Commands.soundStop()), [2, 1])
        XCTAssertEqual([UInt8](Commands.soundTouch(on: true)), [2, 2, 40, 1])
        XCTAssertEqual([UInt8](Commands.soundTouch(on: false, volume: 120)), [2, 2, 100, 0])
        XCTAssertEqual([UInt8](Commands.touchOnboarding()), [1, 37])
    }

    func testNavLayouts() {
        typealias C = Commands.NavColour
        XCTAssertEqual([UInt8](Commands.navOff()), [1, 3])
        XCTAssertEqual([UInt8](Commands.navReroute()), [1, 2])
        XCTAssertEqual([UInt8](Commands.navPointerOff()), [1, 23])

        // Distance: big-endian, bit 31 = imperial; imperial values are feet (round to 0.1, then int).
        XCTAssertEqual(Commands.metric4(1234, metric: true), [0x00, 0x00, 0x04, 0xd2])
        XCTAssertEqual(Commands.metric4(100, metric: false), [0x80, 0x00, 0x01, 0x48])   // 328 ft
        XCTAssertEqual(Commands.metric4(-20, metric: true), [0, 0, 0, 0])
        // Signed int16 angles.
        XCTAssertEqual(Commands.angle16(-90), [0xff, 0xa6])
        // Text: Latin-1, NUL-terminated, ≤ 29 characters.
        XCTAssertEqual(Commands.navText("Ñu€", header: 11), [0xd1, 0x75, 0x3f, 0])
        XCTAssertEqual(Commands.navText("d’Aragó – 2", header: 11), [0x64, 0x27] + Array("Arag".utf8) + [0xf3] + Array(" - 2".utf8) + [0])
        XCTAssertEqual(Commands.navText("Macia\u{0300}", header: 11), Array("Maci".utf8) + [0xe0, 0])   // composed
        XCTAssertEqual(Commands.navText(String(repeating: "a", count: 40), header: 3).count, 30)

        // Colours of the official app.
        XCTAssertEqual([C.progress(0).hue, C.progress(50).hue, C.progress(100).hue], [17, 42, 67])

        // Pointer: [1,22, c(3), angle(2)] + D(4) + text.
        XCTAssertEqual([UInt8](Commands.navPointer(angle: -45, distance: 120, text: "Go",
                                                    colour: C.offPath)),
                       [1, 22, 30, 255, 255, 0xff, 0xd3, 0, 0, 0, 120, 0x47, 0x6f, 0])
        // Standby: [1,24, c(3)] + D(4) + text.
        XCTAssertEqual([UInt8](Commands.navPointerStandby(distance: 100, text: "", colour: C.progress(0))),
                       [1, 24, 17, 255, 255, 0, 0, 0, 100, 0])
        // Angle (quick): 22-byte header + text; sameTurn adds 128 to the progress byte (40 → 0xa8).
        XCTAssertEqual([UInt8](Commands.navAngle(colour: C.turn, angle: 90, progress: 40, sameTurn: true,
                                                  nextColour: C.turn, nextAngle: -30, nextProgress: 0,
                                                  distance: 55, nextDistance: 0, text: "")),
                       [1, 17, 67, 255, 255, 0x00, 0x5a, 0xa8, 67, 255, 255, 0xff, 0xe2, 0,
                        0, 0, 0, 55, 0, 0, 0, 0, 0])
        // Arrival (onDestinationReached): destination glyph, progress 100, distance 0, title.
        XCTAssertEqual([UInt8](Commands.nav(stepType: 0, progress: 100, distance: 0, text: "A")),
                       [1, 1, 67, 255, 255, 0, 100, 0, 0, 0, 0, 0x41, 0])
        // Sounds: [2,0, volume, repeat] + track.
        XCTAssertEqual([UInt8](Commands.soundPlay(volume: 50, track: Commands.NavSound.turnNow)),
                       [2, 0, 50, 0, 0, 0, 0, 0x6a])
        // Error animation (playErrorAnimation).
        XCTAssertEqual([UInt8](Commands.errorNotification()).prefix(18),
                       [1, 7, 253, 237, 255, 253, 237, 0, 0, 0xc8, 0, 0x32, 0, 0x64, 0, 0x0a, 3, 69])
    }

    /// Navigation card: `[1,35, 0, mask LE(4)] + D(4) + angle(2) + white(3) + text`, a 16-byte header.
    func testCarouselNavigationCardLayout() {
        let mask: UInt16 = 0x02fd
        XCTAssertEqual([UInt8](Commands.carouselNavigationCard(mask: mask)), [1, 35, 0, 0xfd, 0x02, 0, 0])
        XCTAssertEqual([UInt8](Commands.carouselNavigationCard(mask: mask, distance: 120, angle: -45, text: "Go")),
                       [1, 35, 0, 0xfd, 0x02, 0, 0, 0, 0, 0, 120, 0xff, 0xd3, 0, 0, 220, 0x47, 0x6f, 0])
        // 29 characters + NUL after the header: 46 bytes, within the 80 the firmware takes.
        let long = [UInt8](Commands.carouselNavigationCard(mask: mask, distance: 0, text: String(repeating: "x", count: 60)))
        XCTAssertEqual(long.count, 16 + 30)
        XCTAssertEqual(long.last, 0)
    }

    func testCallAlertLayouts() {
        // Icon type 0, repeat 60 (about 30 s), text + NUL.
        XCTAssertEqual([UInt8](Commands.incomingCall(text: "Llamada")),
                       [1, 7, 143, 219, 198, 143, 219, 0, 0, 100, 1, 0, 0, 100, 0, 0, 60, 0,
                        0x4c, 0x6c, 0x61, 0x6d, 0x61, 0x64, 0x61, 0])
        // The firmware keeps 30 bytes of text, NUL included.
        let long = [UInt8](Commands.incomingCall(text: String(repeating: "x", count: 60)))
        XCTAssertEqual(long.count, 18 + 30)
        XCTAssertEqual(long.last, 0)
        XCTAssertEqual([UInt8](Commands.notificationOff()), [1, 8])
        // Ringtone: volume 50, played 19 times; 8 notes + the silence.
        XCTAssertEqual([UInt8](Commands.callSound()).prefix(8), [2, 0, 50, 18, 0x01, 0xd2, 0, 0x50])
        XCTAssertEqual(Commands.callTrack.count, 36)
        XCTAssertEqual(Commands.callTrack.suffix(4), [0, 0, 0x03, 0xe8])
        // Rain: storm icon, repeat 10 (about 6 s).
        XCTAssertEqual([UInt8](Commands.rainAlert(text: "Rain now")).prefix(18),
                       [1, 7, 170, 220, 255, 170, 220, 0, 0, 200, 0, 50, 0, 100, 0, 10, 10, 32])
    }

    func testDeviceLayouts() {
        XCTAssertEqual([UInt8](Commands.compassCalibrate()), [4, 3])
        XCTAssertEqual([UInt8](Commands.getState()), [4, 1])
        XCTAssertEqual([UInt8](Commands.shutdown()), [4, 4])
        // localization: [4,6] + 8-byte LE time + language
        // time 0x0102 → LE bytes 02 01 00 00 00 00 00 00, lang "en" = 0x65 0x6e
        XCTAssertEqual([UInt8](Commands.localization(unixSeconds: 0x0102, language: "en")),
                       [4, 6, 0x02, 0x01, 0, 0, 0, 0, 0, 0, 0x65, 0x6e])
    }
}
