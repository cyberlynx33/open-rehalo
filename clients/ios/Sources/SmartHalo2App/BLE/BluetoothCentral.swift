import Foundation
import Combine
import CoreBluetooth
import SH2Protocol

/// A SmartHalo device found during scanning.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID              // peripheral.identifier (stable per iPhone)
    let name: String
    let rssi: Int
    fileprivate let peripheral: CBPeripheral?   // nil for the demo device (no Bluetooth)

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool { lhs.id == rhs.id }

    /// The fictitious device used by demo mode (no real Bluetooth peripheral).
    static let demo = DiscoveredDevice(
        id: UUID(uuidString: "DE110000-0000-4000-8000-000000000001")!,
        name: "Demo SmartHalo",
        rssi: -42,
        peripheral: nil
    )
}

/// Owns the `CBCentralManager`: scanning, connection lifecycle, and manufacturing a
/// `BluetoothTransport` for a connected peripheral.
///
/// CoreBluetooth callbacks arrive on `bleQueue` (a private serial queue). `@Published` state is
/// published on the main actor via `publishMain`. Continuations are only ever touched on `bleQueue`.
final class BluetoothCentral: NSObject, ObservableObject, @unchecked Sendable {

    enum CentralError: Error {
        case poweredOff
        case connectFailed(String)
        case disconnected(String)
        case superseded            // a newer connect() replaced this pending one
        case cancelled             // disconnect() was called while the connect was pending
    }

    /// A peripheral link went down. `unexpected` is false when the app asked for it (`disconnect()`).
    struct DisconnectEvent {
        let id: UUID
        let unexpected: Bool
    }

    /// App-wide instance. CoreBluetooth's `CBCentralManager` is effectively process-global, and
    /// SwiftUI views (scan list) plus `DeviceController` must share the same manager so that a
    /// peripheral discovered during scanning can be connected later.
    static let shared = BluetoothCentral()

    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var discovered: [DiscoveredDevice] = []

    /// Every link drop, delivered on the main thread. `HaloConnection` uses it to auto-reconnect.
    let disconnects = PassthroughSubject<DisconnectEvent, Never>()

    /// Created on first use (`activate()`): creating it is what triggers iOS's Bluetooth permission
    /// prompt, so it waits until there is a ring to reconnect to or the pairing step scans.
    private var manager: CBCentralManager?
    private let bleQueue = DispatchQueue(label: "com.sh2.smarthalo2.ble")

    // Connection coordination (touched only on bleQueue).
    private var connectContinuation: CheckedContinuation<BluetoothTransport, Error>?
    private var connectingPeripheral: CBPeripheral?
    private var activeTransport: BluetoothTransport?
    /// Identifiers whose next disconnect was requested by the app (so it isn't "unexpected").
    private var intentionalDisconnects: Set<UUID> = []

    override init() {
        super.init()
    }

    /// Start Bluetooth (and, the first time, iOS's permission prompt). Called where the app has a
    /// reason the user has seen: a saved Halo to reconnect to, the pairing step's scan. Until then
    /// `state` stays `.unknown`.
    func activate() {
        bleQueue.async { self.ensureManager() }
    }

    /// On `bleQueue`. The system's own "turn on Bluetooth" alert is off: the app's screens say it.
    private func ensureManager() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: bleQueue,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    // MARK: - Scanning

    func startScan() {
        bleQueue.async {
            self.ensureManager()
            guard let manager = self.manager, manager.state == .poweredOn else { return }
            self.publishMain { self.discovered = []; self.isScanning = true }
            // Scan by the vendor service UUID, as instructed by the protocol port.
            //
            // CAVEAT: some units only put the 16-bit `0x5348` ("SH") UUID in the advertisement
            // (see docs/protocol/ble-link.md §1), so filtering strictly by the 128-bit service can
            // miss them. If a known device never appears, flip `scanByServiceOnly` to false to scan
            // broadly and match by name.
            let scanByServiceOnly = true
            let services: [CBUUID]? = scanByServiceOnly
                ? [CBUUID(string: Frame.UUIDs.service), CBUUID(string: "5348")]
                : nil
            manager.scanForPeripherals(
                withServices: services,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    func stopScan() {
        bleQueue.async {
            self.manager?.stopScan()
            self.publishMain { self.isScanning = false }
        }
    }

    // MARK: - Known devices (auto-connect)

    /// Rebuild a `DiscoveredDevice` for a peripheral this iPhone has seen before (the saved
    /// "my Halo"), without scanning. Returns nil if CoreBluetooth no longer knows the identifier or
    /// Bluetooth isn't powered on. Connecting to it is a *pending* connection: CoreBluetooth
    /// completes it whenever the ring comes into range (it never times out).
    func retrieveDevice(id: UUID, name fallbackName: String?) async -> DiscoveredDevice? {
        await withCheckedContinuation { cont in
            bleQueue.async {
                self.ensureManager()
                guard let manager = self.manager, manager.state == .poweredOn,
                      let p = manager.retrievePeripherals(withIdentifiers: [id]).first
                else { cont.resume(returning: nil); return }
                cont.resume(returning: DiscoveredDevice(
                    id: p.identifier,
                    name: p.name ?? fallbackName ?? "SmartHalo",
                    rssi: 0,
                    peripheral: p
                ))
            }
        }
    }

    // MARK: - Connect

    /// Connect to a device, discover the vendor service + characteristics, and return a ready
    /// `BluetoothTransport`. Call `Session(transport:).open()` afterwards.
    func connect(_ device: DiscoveredDevice) async throws -> BluetoothTransport {
        stopScan()
        guard let peripheral = device.peripheral else {
            throw CentralError.connectFailed("demo device has no Bluetooth peripheral")
        }
        SH2Log.log("central: connecting to “\(device.name)” [\(device.id.uuidString.prefix(8))]…")
        let transport: BluetoothTransport = try await withCheckedThrowingContinuation { cont in
            bleQueue.async {
                self.ensureManager()
                guard let manager = self.manager, manager.state == .poweredOn else {
                    cont.resume(throwing: CentralError.poweredOff); return
                }
                // Never leak a pending continuation: fail the older connect before replacing it.
                if let old = self.connectContinuation {
                    self.connectContinuation = nil
                    old.resume(throwing: CentralError.superseded)
                }
                // A pending connect to another ring would otherwise stay armed in CoreBluetooth and
                // complete, into nobody's hands, whenever that ring came into range.
                if let old = self.connectingPeripheral, old.identifier != peripheral.identifier {
                    self.intentionalDisconnects.insert(old.identifier)
                    manager.cancelPeripheralConnection(old)
                }
                self.intentionalDisconnects.remove(peripheral.identifier)
                self.connectContinuation = cont
                self.connectingPeripheral = peripheral
                // Diagnostics: already connected to this iPhone means a link the previous launch
                // left up, or another app's. Either way the ring may still be on someone else's keys.
                let service = CBUUID(string: Frame.UUIDs.service)
                if manager.retrieveConnectedPeripherals(withServices: [service])
                    .contains(where: { $0.identifier == peripheral.identifier }) {
                    SH2Log.log("central: the Halo is already connected to this iPhone (a link left up by the previous launch, or another app)")
                }
                manager.connect(peripheral, options: nil)
            }
        }
        // Discovery runs on the transport (which is now the peripheral's delegate).
        SH2Log.log("central: connected — discovering vendor service…")
        try await transport.discover()
        SH2Log.log("central: service + characteristics discovered")
        return transport
    }

    func disconnect() {
        bleQueue.async {
            if let p = self.connectingPeripheral {
                self.intentionalDisconnects.insert(p.identifier)
                self.manager?.cancelPeripheralConnection(p)
            }
            // Cancelling a *pending* connect doesn't reliably produce a delegate callback, so fail
            // the waiting connect() here.
            if let cont = self.connectContinuation {
                self.connectContinuation = nil
                cont.resume(throwing: CentralError.cancelled)
            }
            // Tear the transport down now: `didDisconnectPeripheral` arrives after this method has
            // let go of it, so it would never be told, and a `discover()`/`enableNotifications()`
            // still waiting on it would hang.
            self.activeTransport?.handleDisconnect()
            self.connectingPeripheral = nil
            self.activeTransport = nil
        }
    }

    private func publishMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}

// MARK: - CBCentralManagerDelegate (callbacks on bleQueue)

extension BluetoothCentral: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let s = central.state
        if s != .poweredOn {
            // Bluetooth went away (off / reset / unauthorized): CoreBluetooth drops every link and
            // pending connect without per-peripheral callbacks, so fail them here.
            activeTransport?.handleDisconnect()
            if let cont = connectContinuation {
                connectContinuation = nil
                cont.resume(throwing: CentralError.poweredOff)
            }
            if let p = connectingPeripheral {
                let unexpected = intentionalDisconnects.remove(p.identifier) == nil
                let event = DisconnectEvent(id: p.identifier, unexpected: unexpected)
                publishMain { self.disconnects.send(event) }
            }
            connectingPeripheral = nil
            activeTransport = nil
        }
        publishMain { self.state = s }
    }

    func centralManager(_ central: CBCentralManager,
                         didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any],
                         rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? "Unknown"
        let device = DiscoveredDevice(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            peripheral: peripheral
        )
        publishMain {
            if let idx = self.discovered.firstIndex(where: { $0.id == device.id }) {
                self.discovered[idx] = device
            } else {
                self.discovered.append(device)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == connectingPeripheral?.identifier, let cont = connectContinuation else {
            // A connect nobody is waiting for any more (an older pending one, to another ring):
            // release the ring instead of holding an unauthenticated link until its 60 s kick-out.
            SH2Log.log("central: a ring no longer wanted connected [\(peripheral.identifier.uuidString.prefix(8))] — releasing it")
            intentionalDisconnects.insert(peripheral.identifier)
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectContinuation = nil
        let transport = BluetoothTransport(peripheral: peripheral, queue: bleQueue)
        activeTransport = transport
        cont.resume(returning: transport)
    }

    func centralManager(_ central: CBCentralManager,
                         didFailToConnect peripheral: CBPeripheral,
                         error: Error?) {
        guard peripheral.identifier == connectingPeripheral?.identifier, let cont = connectContinuation else { return }
        connectContinuation = nil
        SH2Log.log("central: ✗ failed to connect — \(error?.localizedDescription ?? "unknown")")
        cont.resume(throwing: CentralError.connectFailed(error?.localizedDescription ?? "unknown"))
    }

    func centralManager(_ central: CBCentralManager,
                         didDisconnectPeripheral peripheral: CBPeripheral,
                         error: Error?) {
        SH2Log.log("central: ⚡️ disconnected [\(peripheral.identifier.uuidString.prefix(8))] — \(error?.localizedDescription ?? "clean")")
        // Tear down the transport's notification stream so the Session's in-flight wait fails fast
        // instead of hanging (this is the key fix for the reset-challenge freeze: the ring drops
        // the link right after resetPassword un-pairs it). Only this ring's transport: with two
        // rings, the old link's late disconnect must not kill the new one.
        if let transport = activeTransport, transport.peripheralID == peripheral.identifier {
            transport.handleDisconnect()
            activeTransport = nil
        }
        if peripheral.identifier == connectingPeripheral?.identifier {
            // If we were still waiting on a connect, surface it as a failure.
            if let cont = connectContinuation {
                connectContinuation = nil
                cont.resume(throwing: CentralError.disconnected(error?.localizedDescription ?? "disconnected"))
            }
            connectingPeripheral = nil
        }
        let unexpected = intentionalDisconnects.remove(peripheral.identifier) == nil
        let event = DisconnectEvent(id: peripheral.identifier, unexpected: unexpected)
        publishMain { self.disconnects.send(event) }
    }
}
