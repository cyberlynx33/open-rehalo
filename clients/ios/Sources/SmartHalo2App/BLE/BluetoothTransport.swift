import Foundation
import CoreBluetooth
import SH2Protocol

/// CoreBluetooth implementation of the protocol-layer `Transport` for a single connected
/// peripheral. Owns the peripheral's delegate and bridges the GATT characteristics to the
/// bslink framing expected by `Session`.
///
/// Concurrency: every CoreBluetooth interaction and every mutation of this object's state runs on
/// `queue` — the same serial `DispatchQueue` the `CBCentralManager` was created with. Delegate
/// callbacks also arrive on `queue`. Because all access is confined to that one serial queue, the
/// type is safe to share with the `Session` actor; hence `@unchecked Sendable`.
final class BluetoothTransport: NSObject, Transport, @unchecked Sendable {

    enum TransportError: Error {
        case characteristicNotFound(String)
        case serviceNotFound
        case discoveryFailed(String)
        case notifyFailed(String)
        case disconnected
        case writeFailed(String)
        /// Discovery or CCCD enabling got no callback in `setupTimeout`.
        case timedOut(String)
    }

    /// Backstop for service discovery and CCCD enabling. CoreBluetooth doesn't always call back
    /// (a link that drops in between, Bluetooth switched off), and without it `connect()` would wait
    /// forever; the ring kicks an unauthenticated central out after 60 s anyway.
    static let setupTimeout: DispatchTimeInterval = .seconds(15)

    private let peripheral: CBPeripheral
    private let queue: DispatchQueue

    /// The peripheral this transport belongs to (so a disconnect of another ring is ignored).
    var peripheralID: UUID { peripheral.identifier }

    /// Discovered characteristics keyed by uppercased UUID string.
    private var characteristics: [String: CBCharacteristic] = [:]

    // Discovery coordination.
    private var discoverContinuation: CheckedContinuation<Void, Error>?

    // Notify-enable coordination.
    private var notifyContinuation: CheckedContinuation<Void, Error>?
    private var notifyRemaining = 0
    private var notifyFinished = false

    // One in-flight write at a time (Session awaits each write before issuing the next).
    //
    // IMPORTANT: the bslink characteristics are **Write-WITH-Response only** in firmware —
    // `bleapp_char_add` sets `char_props.write` but NOT `write_wo_resp` (reference bleapp.c:700).
    // So a Write-Without-Response is silently dropped by CoreBluetooth and the device never
    // receives the command. We therefore write with `.withResponse` and await `didWriteValueFor`.
    private var writeContinuation: CheckedContinuation<Void, Error>?

    // Notification stream (unbounded buffer so early notifications are not dropped).
    private let stream: AsyncStream<SH2Notification>
    private let streamContinuation: AsyncStream<SH2Notification>.Continuation

    // Set once the peripheral disconnects; finishes the stream so `Session` stops waiting.
    private var disconnected = false

    init(peripheral: CBPeripheral, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.queue = queue
        var cont: AsyncStream<SH2Notification>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.streamContinuation = cont
        super.init()
        peripheral.delegate = self
    }

    func notificationStream() -> AsyncStream<SH2Notification> { stream }

    /// Called by `BluetoothCentral` when the peripheral disconnects. Finishes the notification
    /// stream, which ends the `Session` consumer loop, and fails whatever was waiting on this link:
    /// service discovery, CCCD enabling or a write. CoreBluetooth gives no callback for a request
    /// made on a peripheral that is no longer connected, so without this `connect()` would hang.
    func handleDisconnect() {
        queue.async {
            guard !self.disconnected else { return }
            self.disconnected = true
            self.streamContinuation.finish()
            self.resumeDiscover(throwing: TransportError.disconnected)
            self.resumeNotify(throwing: TransportError.disconnected)
            let cont = self.writeContinuation
            self.writeContinuation = nil
            cont?.resume(throwing: TransportError.disconnected)
        }
    }

    // MARK: - Discovery (called by BluetoothCentral after connect)

    /// Discover the vendor service and its characteristics. Resolves once all chars are known.
    func discover() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.disconnected { cont.resume(throwing: TransportError.disconnected); return }
                self.discoverContinuation = cont
                self.peripheral.discoverServices([CBUUID(string: Frame.UUIDs.service)])
                self.queue.asyncAfter(deadline: .now() + Self.setupTimeout) { [weak self] in
                    self?.resumeDiscover(throwing: TransportError.timedOut("service discovery"))
                }
            }
        }
    }

    // MARK: - Transport

    func enableNotifications() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.disconnected { cont.resume(throwing: TransportError.disconnected); return }
                let notifyChars = Frame.UUIDs.allNotify.compactMap { self.characteristics[$0] }
                guard !notifyChars.isEmpty else {
                    cont.resume(throwing: TransportError.serviceNotFound); return
                }
                self.notifyContinuation = cont
                self.notifyRemaining = notifyChars.count
                self.notifyFinished = false
                for ch in notifyChars { self.peripheral.setNotifyValue(true, for: ch) }
                self.queue.asyncAfter(deadline: .now() + Self.setupTimeout) { [weak self] in
                    self?.resumeNotify(throwing: TransportError.timedOut("enabling notifications"))
                }
            }
        }
    }

    func write(uuid: String, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.disconnected { cont.resume(throwing: TransportError.disconnected); return }
                guard let ch = self.characteristics[uuid.uppercased()] else {
                    cont.resume(throwing: TransportError.characteristicNotFound(uuid)); return
                }
                // bslink chars are Write-WITH-Response only (see note on `writeContinuation`), so we
                // must use `.withResponse` and wait for the confirmation in `didWriteValueFor`.
                // `Session` serializes writes, so at most one continuation is in flight.
                self.writeContinuation = cont
                self.peripheral.writeValue(data, for: ch, type: .withResponse)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate (all callbacks arrive on `queue`)

extension BluetoothTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            resumeDiscover(throwing: TransportError.discoveryFailed(error.localizedDescription))
            return
        }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: Frame.UUIDs.service)
        }) else {
            resumeDiscover(throwing: TransportError.serviceNotFound)
            return
        }
        let wanted = Frame.UUIDs.allNotify.map { CBUUID(string: $0) }
        peripheral.discoverCharacteristics(wanted, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            resumeDiscover(throwing: TransportError.discoveryFailed(error.localizedDescription))
            return
        }
        for ch in service.characteristics ?? [] {
            characteristics[ch.uuid.uuidString.uppercased()] = ch
        }
        let found = Frame.UUIDs.allNotify.filter { characteristics[$0] != nil }.count
        SH2Log.log("transport: \(characteristics.count) chars, \(found)/\(Frame.UUIDs.allNotify.count) bslink notify chars present")
        resumeDiscover(throwing: nil)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard !notifyFinished else { return }
        if let error {
            resumeNotify(throwing: TransportError.notifyFailed(error.localizedDescription))
            return
        }
        notifyRemaining -= 1
        if notifyRemaining <= 0 { resumeNotify(throwing: nil) }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        streamContinuation.yield(
            SH2Notification(uuid: characteristic.uuid.uuidString.uppercased(), data: value)
        )
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let cont = writeContinuation else { return }
        writeContinuation = nil
        if let error {
            cont.resume(throwing: TransportError.writeFailed(error.localizedDescription))
        } else {
            cont.resume()
        }
    }

    private func resumeDiscover(throwing error: Error?) {
        guard let cont = discoverContinuation else { return }
        discoverContinuation = nil
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }

    /// Resume `enableNotifications()` once, whatever ends it first: the last CCCD callback, an
    /// error, the disconnect or the backstop timer.
    private func resumeNotify(throwing error: Error?) {
        guard let cont = notifyContinuation else { return }
        notifyContinuation = nil
        notifyFinished = true
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }
}
