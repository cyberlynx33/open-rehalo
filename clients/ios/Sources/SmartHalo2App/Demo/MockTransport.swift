import Foundation
import SH2Protocol

/// Canned data a fictitious SmartHalo reports in demo mode.
struct DemoData {
    var firmware: [UInt8] = [2, 3, 0, 0]        // fw 2.3.0.0
    var bootloader: [UInt8] = [1, 2, 0, 0]      // bl 1.2.0.0
    var serial = "SH2-DEMO-0001"
    /// getState: 80 %, not charging, light ready/off, 23 °C, unplugged (`returnState` layout).
    var state: [UInt8] = [80, 0, 0, 0, 1, 0, 23, 0, 0]
    var alarmSeed: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
}

/// A **fake SmartHalo** `Transport` used only by demo mode: it parses each outgoing bslink frame's
/// `{service, cmd}` and feeds back a canned, well-formed **plaintext** reply on the DOWN channel, so
/// the real `Session`/`Frame` layers run unchanged with no Bluetooth and no real device.
///
/// Demo sessions skip the ECDH handshake (`Session.authenticateForDemo`), so the cipher stays `nil`
/// and every request/reply is plaintext — the mock never needs to encrypt/decrypt.
final class MockTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var reqPayload = Data()
    private let data: DemoData
    // Simulated alarm (guarded by `lock`), like AlarmTask.c: `alarmConfigure` {3,3} turns it ON/OFF,
    // `simulateAlarm()` counts a trigger while it's ON, every report read zeroes the count.
    private var alarmOn = false
    private var alarmVigilant = true
    private var alarmTriggers: UInt8 = 0

    private let stream: AsyncStream<SH2Notification>
    private let cont: AsyncStream<SH2Notification>.Continuation

    init(data: DemoData = DemoData()) {
        self.data = data
        var c: AsyncStream<SH2Notification>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        self.cont = c
    }

    func enableNotifications() async throws { /* nothing to enable on a mock */ }

    func notificationStream() -> AsyncStream<SH2Notification> { stream }

    func write(uuid: String, data payload: Data) async throws {
        lock.lock(); defer { lock.unlock() }
        let u = uuid.uppercased()
        if Frame.UUIDs.payload.contains(u) {
            reqPayload.append(payload)
        } else if u == Frame.UUIDs.ctrl {
            // CTRL = [len, crypted]; plaintext in demo, so the payload prefix IS the request.
            let len = Int([UInt8](payload).first ?? 0)
            let appData = Data(reqPayload.prefix(len))
            reqPayload = Data()
            emit(reply(to: appData))
        }
    }

    // MARK: - Device emulation

    private func reply(to appData: Data) -> Data {
        let b = [UInt8](appData)
        let service = b.count > 0 ? b[0] : 0xFF
        let cmd = b.count > 1 ? b[1] : 0xFF
        let ok = ReturnCode.ok.rawValue
        switch (service, cmd) {
        case (0, 0):  return Data([ok] + data.firmware + data.bootloader)   // getVersions
        case (0, 5):  return Data([ok]) + Data(data.serial.utf8)            // getSerial
        case (4, 1):  return Data([ok] + data.state)                        // getState
        case (3, 0):                                                        // alarmReport
            // [OK, armed, triggerCount, severity, mode]; the count resets on read
            defer { alarmTriggers = 0 }
            return Data([ok, alarmOn ? 1 : 0, alarmTriggers, alarmVigilant ? 1 : 0, alarmOn ? 1 : 0])
        case (3, 3):                                    // alarmConfigure [3,3, seed(4), code, len, armed, vigilant]
            if b.count > 8 { alarmOn = b[8] == 1 }
            if b.count > 9 { alarmVigilant = b[9] == 1 }
            return Data([ok])
        case (3, 1):  return Data([ok] + data.alarmSeed)                    // alarmGetSeed (4-byte seed)
        default:      return Data([ok])                                     // every control cmd → OK
        }
    }

    /// Demo: someone moved the bike while you were away. If the simulated alarm is ON, the ring
    /// "sounded" (trigger count +1), to be collected by the next report.
    func simulateAlarm() {
        lock.lock()
        if alarmOn { alarmTriggers &+= 1 }
        lock.unlock()
    }

    /// Frame the reply exactly like the device does (payload chunks on the DOWN PAYLOAD chars, then
    /// the DOWN CTRL char) and push it onto the notification stream the `Session` is consuming.
    /// `up: true` = an unsolicited UP-channel notification instead of a DOWN reply.
    private func emit(_ reply: Data, up: Bool = false) {
        guard let enc = try? Frame.encodeMessage(reply, cipher: nil) else { return }
        let payloadUUIDs = up ? Frame.UUIDs.upPayload : Frame.UUIDs.payload
        for (i, chunk) in enc.chunks.enumerated() where i < payloadUUIDs.count {
            cont.yield(SH2Notification(uuid: payloadUUIDs[i], data: chunk))
        }
        cont.yield(SH2Notification(uuid: up ? Frame.UUIDs.upCtrl : Frame.UUIDs.ctrl, data: enc.ctrl))
    }
}
