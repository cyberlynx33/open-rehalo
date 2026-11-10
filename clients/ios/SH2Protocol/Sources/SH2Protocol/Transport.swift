import Foundation

/// A single device → central notification carrying the originating characteristic UUID.
public struct SH2Notification: Sendable {
    public let uuid: String
    public let data: Data
    public init(uuid: String, data: Data) {
        self.uuid = uuid
        self.data = data
    }
}

/// Abstract BLE transport the `Session` drives. Mirrors the duck-typed `Transport` in
/// `sh2-core/src/session.mjs` (`write` + `subscribe`), adapted to Swift concurrency.
///
/// The concrete iOS implementation is `BluetoothTransport` (CoreBluetooth). A mock conformer is
/// trivial to write for `swift test` on macOS.
///
/// Ordering contract (critical): `notifications` MUST deliver values in the exact order the
/// device sent them (all PAYLOAD chunks, then the CTRL). CoreBluetooth guarantees this because
/// it dispatches `didUpdateValueFor` serially on the manager's queue.
public protocol Transport: AnyObject, Sendable {
    /// Enable notifications (CCCD) on every bslink characteristic. Called once by `Session.open()`.
    /// Equivalent to the `subscribe(...)` calls in the JS `Session.open`.
    func enableNotifications() async throws

    /// Write a chunk to the given characteristic and return once the device has acknowledged it:
    /// a **write with response**. The ring's characteristics are write-with-response only
    /// (`bleapp.c:700-702`, no `write_wo_resp`), so a write without response is dropped and the
    /// command never arrives.
    func write(uuid: String, data: Data) async throws

    /// Ordered stream of every incoming notification. The `Session` is the sole consumer.
    func notificationStream() -> AsyncStream<SH2Notification>
}
