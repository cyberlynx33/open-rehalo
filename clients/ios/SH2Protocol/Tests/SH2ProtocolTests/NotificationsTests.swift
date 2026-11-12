import XCTest
@testable import SH2Protocol

/// UP-channel notification + alarm report parsing (ports of the official app's
/// `BleNotificationController` and `AlarmReport`).
final class NotificationsTests: XCTestCase {

    func testAlarmReport() {
        let r = AlarmReport(reply: Data([0, 1, 3, 1, 0]))
        XCTAssertEqual(r, AlarmReport(isArmed: true, triggerCount: 3, isVigilant: true))
        XCTAssertEqual(AlarmReport(reply: Data([0, 0, 0, 0])),
                       AlarmReport(isArmed: false, triggerCount: 0, isVigilant: false))
        XCTAssertNil(AlarmReport(reply: Data([1, 1, 3, 1, 0])))   // RET_FAIL
        XCTAssertNil(AlarmReport(reply: Data([0, 1])))             // too short
    }

    func testMovement() {
        XCTAssertEqual(UpNotification(Data([2, 1])), .movement(true))
        XCTAssertEqual(UpNotification(Data([2, 0])), .movement(false))
        XCTAssertEqual(UpNotification(Data([2, 7])), .unknown(Data([2, 7])))
    }

    func testLight() {
        XCTAssertEqual(UpNotification(Data([3, 1, 1])), .light(isOn: true, settingOn: true, fromTouch: nil))
        XCTAssertEqual(UpNotification(Data([3, 0, 1, 1])), .light(isOn: true, settingOn: false, fromTouch: true))
        XCTAssertEqual(UpNotification(Data([3, 1, 0, 0])), .light(isOn: false, settingOn: true, fromTouch: false))
    }

    func testDeviceState() {
        // [OK, soc, charging, compass(2), lightReady, lightShowing, temp, plugged, travel]
        XCTAssertEqual(DeviceState(reply: Data([0, 90, 1, 0, 0, 1, 1, 27, 1, 0])),
                       DeviceState(stateOfCharge: 90, charging: true, lightOn: true, temperature: 27, plugged: true))
        XCTAssertEqual(DeviceState(reply: Data([0, 40, 0])), DeviceState(stateOfCharge: 40, charging: false))
        XCTAssertNil(DeviceState(reply: Data([1, 40, 0])))
        XCTAssertNil(DeviceState(reply: Data([0, 200, 0])))
    }

    func testTouchAndOthers() {
        // mask 0b101, 3 taps → long, short, long
        XCTAssertEqual(UpNotification(Data([0, 0b101, 3])), .touch("lsl"))
        XCTAssertEqual(UpNotification(Data([4])), .deviceInfo(stateOfCharge: nil, temperature: nil, plugged: nil))
        XCTAssertEqual(UpNotification(Data([4, 80, 0xfb, 1])), .deviceInfo(stateOfCharge: 80, temperature: -5, plugged: true))
        XCTAssertEqual(UpNotification(Data([5, 2])), .carouselPosition(2))
        XCTAssertEqual(UpNotification(Data([0xF8, 0x68, 0x69, 0x00])), .log("hi"))
        XCTAssertEqual(UpNotification(Data()), .unknown(Data()))
    }

    /// A plaintext UP frame pushed by a mock reaches the session's notification handler.
    func testSessionDeliversUpNotification() async throws {
        final class UpMock: Transport, @unchecked Sendable {
            let stream: AsyncStream<SH2Notification>
            let cont: AsyncStream<SH2Notification>.Continuation
            init() {
                var c: AsyncStream<SH2Notification>.Continuation!
                stream = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
                cont = c
            }
            func enableNotifications() async throws {}
            func notificationStream() -> AsyncStream<SH2Notification> { stream }
            func write(uuid: String, data: Data) async throws {}
            func pushUp(_ data: Data) throws {
                let enc = try Frame.encodeMessage(data, cipher: nil)
                for (i, chunk) in enc.chunks.enumerated() {
                    cont.yield(SH2Notification(uuid: Frame.UUIDs.upPayload[i], data: chunk))
                }
                cont.yield(SH2Notification(uuid: Frame.UUIDs.upCtrl, data: enc.ctrl))
            }
        }

        let mock = UpMock()
        let session = Session(transport: mock)
        try await session.open()
        let got = expectation(description: "up notification")
        await session.setNotificationHandler { data in
            if UpNotification(data) == .movement(true) { got.fulfill() }
        }
        try mock.pushUp(Data([2, 1]))
        await fulfillment(of: [got], timeout: 2)
        await session.close()
    }
}
