import XCTest
@testable import SH2Nav

/// The time-based turn notices (`TurnTiming`, docs/APP_SPEC.md M17): the thresholds themselves, and
/// the ring guidance announcing the same corner earlier the faster the rider goes.
final class TurnTimingTests: XCTestCase {

    let lat0 = 45.5, lon0 = -73.6
    func point(north: Double, east: Double, accuracy: Int = 5) -> NavLocation {
        NavLocation(lat0 + north / 111_320,
                    lon0 + east / (111_320 * cos(lat0 * .pi / 180)), accuracy: accuracy)
    }

    /// `length` m north, then `length` m east (a right turn), a point every 10 m.
    func lRoute(length: Double = 600) -> [NavLocation] {
        let n = Int(length / 10)
        return (0...n).map { point(north: Double($0) * 10, east: 0, accuracy: 0) }
            + (1...n).map { point(north: length, east: Double($0) * 10, accuracy: 0) }
    }

    // MARK: - Thresholds

    func testDistancesScaleWithSpeedAndKeepTheMargin() {
        let slow = TurnTiming(speed: 1), fast = TurnTiming(speed: 10)
        XCTAssertEqual(slow.prepareDistance, 30 + 7)
        XCTAssertEqual(slow.orderDistance, 10 + 7)
        XCTAssertEqual(fast.prepareDistance, 300 + 7)
        XCTAssertEqual(fast.orderDistance, 100 + 7)
        XCTAssertEqual(fast.upcomingDistance, 600 + 7)
        XCTAssertEqual(fast.chainDistance, 320)
    }

    func testUnknownOrAbsurdSpeedsCountAsWalkingPace() {
        for speed in [nil, -1.0, 0.0, 0.4, Double.nan, -Double.infinity] {
            XCTAssertEqual(TurnTiming(speed: speed).speed, TurnTiming.minimumSpeed, "\(String(describing: speed))")
        }
    }

    func testPhasesByTimeToTheManoeuvre() {
        let t = TurnTiming(speed: 5)                         // 18 km/h
        XCTAssertEqual(t.phase(atDistance: 400), .far)       // 79 s
        XCTAssertEqual(t.phase(atDistance: 200), .upcoming)  // 39 s
        XCTAssertEqual(t.phase(atDistance: 120), .prepare)   // 23 s
        XCTAssertEqual(t.phase(atDistance: 70), .approach)   // 13 s
        XCTAssertEqual(t.phase(atDistance: 50), .order)      // 9 s
        XCTAssertEqual(t.phase(atDistance: 0), .order)
    }

    func testProgressRunsFromThePrepareToTheOrderDistance() {
        let t = TurnTiming(speed: 5)                         // prepare 157 m, order 57 m
        XCTAssertEqual(t.progress(atDistance: 300), 0)
        XCTAssertEqual(t.progress(atDistance: t.prepareDistance), 0)
        XCTAssertEqual(t.progress(atDistance: 107), 50)
        XCTAssertEqual(t.progress(atDistance: t.orderDistance), 100)
        XCTAssertEqual(t.progress(atDistance: 0), 100)
        XCTAssertEqual(t.progress(atDistance: .nan), 0)
        XCTAssertEqual(TurnTiming.arrivalProgress(atDistance: 160), 0)
        XCTAssertEqual(TurnTiming.arrivalProgress(atDistance: 100), 50)
        XCTAssertEqual(TurnTiming.arrivalProgress(atDistance: 40), 100)
    }

    // MARK: - On the ring

    /// Ride the L at `speed` m/s, one fix a second; the distance to the corner at the first `navAngle`
    /// and at the first turn sound.
    func cornerNotices(speed: Double) -> (arcAt: Double?, orderAt: Double?, sounds: [[UInt8]]) {
        let corner = point(north: 600, east: 0)
        var director = NavDirector(points: lRoute(), title: "Office")
        _ = director.start(ringConnected: true)
        var arcAt: Double?, orderAt: Double?
        var sounds: [[UInt8]] = []
        var north = 0.0
        while north <= 600 {
            let fix = point(north: north, east: 0)
            let r = director.update(fix, speed: speed)
            let d = fix.distance(to: corner)
            if arcAt == nil, r.commands.contains(where: { $0.label == "navAngle" }) { arcAt = d }
            for c in r.commands where c.label == "sound" {
                let bytes = [UInt8](c.data)
                sounds.append(bytes)
                if orderAt == nil, Array(bytes.suffix(Commands.NavSound.turnNow.count)) == Commands.NavSound.turnNow {
                    orderAt = d
                }
            }
            north += speed
        }
        return (arcAt, orderAt, sounds)
    }

    func testTheArcComesEarlierTheFasterTheRiderGoes() {
        let slow = cornerNotices(speed: 3)       // prepare 97 m, order 37 m
        let fast = cornerNotices(speed: 10)      // prepare 307 m, order 107 m
        XCTAssertEqual(slow.arcAt ?? 0, TurnTiming(speed: 3).prepareDistance, accuracy: 3)
        XCTAssertEqual(fast.arcAt ?? 0, TurnTiming(speed: 10).prepareDistance, accuracy: 10)
        XCTAssertEqual(slow.orderAt ?? 0, TurnTiming(speed: 3).orderDistance, accuracy: 3)
        XCTAssertEqual(fast.orderAt ?? 0, TurnTiming(speed: 10).orderDistance, accuracy: 10)
        XCTAssertGreaterThan(fast.arcAt ?? 0, (slow.arcAt ?? 0) * 2)
    }

    /// The arc's progress is the ring's 0…100, full once the order comes.
    func testTheArcFillsToOneHundredAtTheOrder() {
        var director = NavDirector(points: lRoute(), title: "Office")
        _ = director.start(ringConnected: true)
        var progresses: [Int] = []
        var north = 0.0
        while north <= 590 {
            let r = director.update(point(north: north, east: 0), speed: 5)
            progresses += r.commands.filter { $0.label == "navAngle" }.map { Int([UInt8]($0.data)[7] & 0x7f) }
            north += 5
        }
        XCTAssertLessThanOrEqual(progresses.first ?? 99, 5)   // a fix every 5 m: just inside the prepare distance
        XCTAssertEqual(progresses.last, 100)
        XCTAssertEqual(progresses, progresses.sorted())    // never goes back
    }

    /// Slowing down before the corner (a light) doesn't empty the arc, nor take it off the ring.
    func testSlowingDownKeepsTheArcWhereItWas() {
        var director = NavDirector(points: lRoute(), title: "Office")
        _ = director.start(ringConnected: true)
        var north = 0.0
        var before: Int?
        while north <= 500 {                          // 100 m from the corner at 5 m/s: 57 % or so
            let r = director.update(point(north: north, east: 0), speed: 5)
            if let a = r.commands.last(where: { $0.label == "navAngle" }) { before = Int([UInt8](a.data)[7] & 0x7f) }
            north += 5
        }
        XCTAssertGreaterThan(before ?? 0, 30)
        // Stopped: at walking pace the prepare distance is 37 m, well short of the 100 m left.
        var stopped: [Int] = []
        var removed = false
        for _ in 0..<5 {
            let r = director.update(point(north: 500, east: 0), speed: 0)
            stopped += r.commands.filter { $0.label == "navAngle" }.map { Int([UInt8]($0.data)[7] & 0x7f) }
            removed = removed || r.commands.contains { $0.label == "navOff" }
        }
        XCTAssertFalse(removed)
        XCTAssertFalse(stopped.isEmpty)
        XCTAssertTrue(stopped.allSatisfy { $0 >= (before ?? 0) })
    }

    /// Two corners 100 m apart at 5 m/s (chain distance 160 m): the second arc rides behind the first.
    /// 300 m apart they're announced one after the other.
    func testCloseTurnsAreChained() {
        func nextProgress(gap: Double) -> [Int] {
            var route: [NavLocation] = (0...30).map { point(north: Double($0) * 10, east: 0, accuracy: 0) }
            let steps = Int(gap / 10)
            route += (1...steps).map { point(north: 300, east: Double($0) * 10, accuracy: 0) }
            route += (1...30).map { point(north: 300 + Double($0) * 10, east: gap, accuracy: 0) }
            var director = NavDirector(points: route, title: "Office")
            _ = director.start(ringConnected: true)
            var out: [Int] = []
            var north = 0.0
            while north <= 295 {
                let r = director.update(point(north: north, east: 0), speed: 5)
                out += r.commands.filter { $0.label == "navAngle" }.map { Int([UInt8]($0.data)[13]) }
                north += 5
            }
            return out
        }
        XCTAssertTrue(nextProgress(gap: 100).contains { $0 > 0 })
        XCTAssertTrue(nextProgress(gap: 300).allSatisfy { $0 == 0 })
    }

    // MARK: - Arrival

    /// The ride ends within `arrivalRadius` of the end, with the arrival notice from 160 m, and never
    /// at the start of a loop (the share of the route ridden is under 10 %).
    func testArrivalWithinFortyMetresOncePastTenPercent() {
        var director = NavDirector(points: lRoute(length: 300), title: "Office")
        _ = director.start(ringConnected: true)
        let end = point(north: 300, east: 300)
        var arrivedAt: Double?, noticeAt: Double?
        var fixes = (0...60).map { point(north: Double($0) * 5, east: 0) }
        fixes += (1...60).map { point(north: 300, east: Double($0) * 5) }
        for (i, fix) in fixes.enumerated() {
            let share = Double(i) / Double(fixes.count - 1)
            let r = director.update(fix, speed: 5, routeShare: share)
            let d = fix.distance(to: end)
            if noticeAt == nil, r.commands.contains(where: { $0.label == "nav" }) { noticeAt = d }
            if r.arrived { arrivedAt = d; break }
        }
        XCTAssertEqual(noticeAt ?? 0, TurnTiming.arrivalNoticeDistance, accuracy: 6)
        XCTAssertNotNil(arrivedAt)
        XCTAssertLessThanOrEqual(arrivedAt ?? 99, TurnTiming.arrivalRadius)
        XCTAssertGreaterThan(arrivedAt ?? 0, TurnTiming.arrivalRadius - 6)
    }

    func testALoopDoesNotArriveAtItsStart() {
        // A loop ending where it starts, with five corners: the first fixes are within 40 m of the end.
        var loop: [NavLocation] = (0...30).map { point(north: Double($0) * 10, east: 0, accuracy: 0) }
        loop += (1...30).map { point(north: 300, east: Double($0) * 10, accuracy: 0) }
        loop += (1...15).map { point(north: 300 - Double($0) * 10, east: 300, accuracy: 0) }
        loop += (1...15).map { point(north: 150, east: 300 - Double($0) * 10, accuracy: 0) }
        loop += (1...15).map { point(north: 150 - Double($0) * 10, east: 150, accuracy: 0) }
        loop += (1...15).map { point(north: 0, east: 150 - Double($0) * 10, accuracy: 0) }
        var director = NavDirector(points: loop, title: "Loop")
        XCTAssertEqual(director.steps.count, 7)
        _ = director.start(ringConnected: true)
        for i in 0...10 {
            let r = director.update(point(north: Double(i) * 5, east: 0), speed: 5, routeShare: Double(i) * 5 / 1200)
            XCTAssertFalse(r.arrived, "fix \(i)")
        }
        // Without a share the original's guard stands in (6 steps or more): not done at its start either.
        var classic = NavDirector(points: loop, title: "Loop")
        _ = classic.start(ringConnected: true)
        for i in 0...10 {
            XCTAssertFalse(classic.update(point(north: Double(i) * 5, east: 0)).arrived, "fix \(i)")
        }
    }
}
