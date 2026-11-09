import Foundation
import Combine
import SH2Protocol

/// App-wide, persisted preferences: whether first-run onboarding is done, whether the user chose the
/// server-backed mode or BLE-only, and the self-hosted `sh2-server` base URL. Stored in UserDefaults
/// (non-sensitive; JWTs live in the Keychain via `TokenStore`).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let onboarded = "sh2.onboarded"
        static let useServer = "sh2.useServer"
        static let serverURL = "sh2.serverURL"
        static let myHaloID = "sh2.myHalo.id"
        static let myHaloName = "sh2.myHalo.name"
        static let demoMode = "sh2.demoMode"
        static let units = "sh2.units"
        static let navNorthUp = "sh2.nav.northUp"          // old north-up Bool, migrated to navOrientation
        static let navOrientation = "sh2.nav.orientation"
        static let mapOrientation = "sh2.map.orientation"
        static let navPrimaryMetric = "sh2.nav.primaryMetric"
        static let routeProfile = "sh2.route.profile"
        static let alarmOn = "sh2.alarm.on"
        static let alarmVigilant = "sh2.alarm.vigilant"
        static let alarmTapCode = "sh2.alarm.tapCode"
        static let ringCards = "sh2.ring.cards"
        static let tapShortcuts = "sh2.ring.tapShortcuts"
        static let lowBatteryAlert = "sh2.battery.lowAlert"
        static let callAlerts = "sh2.call.alerts"
        static let callAlertSound = "sh2.call.sound"
        static let rainAlerts = "sh2.rain.alerts"
        static let syncPasswords = "sh2.keychain.syncPasswords"
        static let navigationEngine = "sh2.nav.engine"
    }

    private let defaults = UserDefaults.standard

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarded) }
    }
    /// True if the user chose the server-backed mode (login). False = BLE-only.
    @Published var useServer: Bool {
        didSet { defaults.set(useServer, forKey: Key.useServer) }
    }
    @Published var serverURLString: String {
        didSet { defaults.set(serverURLString, forKey: Key.serverURL) }
    }

    /// "My Halo": the CoreBluetooth identifier of the paired ring, auto-connected on launch.
    @Published var myHaloID: UUID? {
        didSet { defaults.set(myHaloID?.uuidString, forKey: Key.myHaloID) }
    }
    /// Last known name of "my Halo" (for display before the ring is reachable).
    @Published var myHaloName: String? {
        didSet { defaults.set(myHaloName, forKey: Key.myHaloName) }
    }
    /// True while the app runs the simulated ring (MockTransport) instead of a real one. Persisted so
    /// a relaunch resumes the demo.
    @Published var demoMode: Bool {
        didSet { defaults.set(demoMode, forKey: Key.demoMode) }
    }
    /// Distance / speed units (default from the device locale).
    @Published var units: DistanceUnits {
        didSet { defaults.set(units.rawValue, forKey: Key.units) }
    }

    /// Remembered map orientation per screen: North or Compass (Free is never remembered).
    /// Navigating defaults to Compass (it replaces the old heading-up), the Map tab to North.
    @Published var navOrientation: MapOrientation {
        didSet { defaults.set(navOrientation.rawValue, forKey: Key.navOrientation) }
    }
    @Published var mapOrientation: MapOrientation {
        didSet { defaults.set(mapOrientation.rawValue, forKey: Key.mapOrientation) }
    }
    /// First metric of the Navigating panel (tap cycles it; remembered).
    @Published var navPrimaryMetric: NavPrimaryMetric {
        didSet { defaults.set(navPrimaryMetric.rawValue, forKey: Key.navPrimaryMetric) }
    }
    /// The kind of route to a destination, picked on the map and remembered.
    @Published var routeProfile: RouteProfile {
        didSet { defaults.set(routeProfile.rawValue, forKey: Key.routeProfile) }
    }

    /// Alarm ON (the official "auto activation"): the Halo arms itself whenever no phone is
    /// connected, and disarms when this iPhone reconnects. Sent with `alarmConfigure` {3,3}.
    @Published var alarmOn: Bool {
        didSet { defaults.set(alarmOn, forKey: Key.alarmOn) }
    }
    /// Alarm sensitivity: Vigilant (sounds sooner) or Lenient — the firmware's `severity`. Vigilant
    /// by default, like the official app.
    @Published var alarmVigilant: Bool {
        didSet { defaults.set(alarmVigilant, forKey: Key.alarmVigilant) }
    }
    /// The tap code that arms / disarms the alarm on the Halo itself (no phone needed).
    @Published var alarmTapCode: TapCode? {
        didSet { defaults.set(alarmTapCode?.text, forKey: Key.alarmTapCode) }
    }

    /// The ring's carousel cards (`Commands.CarouselCard` bits) — Halo › Ring cards.
    @Published var ringCards: UInt16 {
        didSet { defaults.set(Int(ringCards), forKey: Key.ringCards) }
    }
    /// Tap shortcuts: tap code (`"sl"`…) → action — Halo › Taps.
    @Published var tapShortcuts: [String: TapAction] {
        didSet { defaults.set(tapShortcuts.mapValues(\.rawValue), forKey: Key.tapShortcuts) }
    }
    /// Notify when the Halo's battery drops to `LowBattery.threshold`.
    @Published var lowBatteryAlert: Bool {
        didSet { defaults.set(lowBatteryAlert, forKey: Key.lowBatteryAlert) }
    }
    /// Show incoming calls on the Halo (`CallAlertController`).
    @Published var callAlerts: Bool {
        didSet { defaults.set(callAlerts, forKey: Key.callAlerts) }
    }
    /// Play the ringtone on the Halo with a call alert.
    @Published var callAlertSound: Bool {
        didSet { defaults.set(callAlertSound, forKey: Key.callAlertSound) }
    }
    /// Warn on the Halo when rain is close (`RainAlertController`). Off by default: it sends the
    /// rider's approximate position to Open-Meteo.
    @Published var rainAlerts: Bool {
        didSet { defaults.set(rainAlerts, forKey: Key.rainAlerts) }
    }

    /// How a ride locates the rider on the route (docs/MAP_MATCHING_SPEC.md): the route matcher with
    /// the wrong-way warning (default), or the official app's classic logic. From the next ride.
    @Published var navigationEngine: RideEngine.Engine {
        didSet { defaults.set(navigationEngine.rawValue, forKey: Key.navigationEngine) }
    }
    /// Keep the ring passwords in iCloud Keychain (Settings › Advanced). Default on, so a lost or
    /// replaced iPhone doesn't force another cold-reboot recovery. Toggling migrates stored items.
    @Published var syncPasswordsToICloud: Bool {
        didSet {
            defaults.set(syncPasswordsToICloud, forKey: Key.syncPasswords)
            KeychainStore.applySync(syncPasswordsToICloud)
        }
    }

    private init() {
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarded)
        useServer = defaults.bool(forKey: Key.useServer)
        serverURLString = defaults.string(forKey: Key.serverURL) ?? ""
        myHaloID = defaults.string(forKey: Key.myHaloID).flatMap(UUID.init(uuidString:))
        myHaloName = defaults.string(forKey: Key.myHaloName)
        demoMode = defaults.bool(forKey: Key.demoMode)
        units = defaults.string(forKey: Key.units).flatMap(DistanceUnits.init(rawValue:))
            ?? .localeDefault
        navOrientation = defaults.string(forKey: Key.navOrientation).flatMap(MapOrientation.init(rawValue:))
            ?? (defaults.bool(forKey: Key.navNorthUp) ? .north : .compass)
        mapOrientation = defaults.string(forKey: Key.mapOrientation).flatMap(MapOrientation.init(rawValue:))
            ?? .north
        navPrimaryMetric = defaults.string(forKey: Key.navPrimaryMetric)
            .flatMap(NavPrimaryMetric.init(rawValue:)) ?? .speed
        routeProfile = defaults.string(forKey: Key.routeProfile).flatMap(RouteProfile.init(rawValue:)) ?? .city
        alarmOn = defaults.bool(forKey: Key.alarmOn)
        alarmVigilant = defaults.object(forKey: Key.alarmVigilant) as? Bool ?? true
        alarmTapCode = defaults.string(forKey: Key.alarmTapCode).flatMap(TapCode.init)
        defaults.removeObject(forKey: "sh2.alarm.locked")       // 2.9.0's "Lock now", gone
        ringCards = (defaults.object(forKey: Key.ringCards) as? Int).map { UInt16(truncatingIfNeeded: $0) }
            ?? RingCard.defaultMask
        tapShortcuts = ((defaults.dictionary(forKey: Key.tapShortcuts) as? [String: String])?
            .compactMapValues(TapAction.init(rawValue:))) ?? TapAction.defaults
        lowBatteryAlert = defaults.object(forKey: Key.lowBatteryAlert) as? Bool ?? true
        callAlerts = defaults.object(forKey: Key.callAlerts) as? Bool ?? true
        callAlertSound = defaults.object(forKey: Key.callAlertSound) as? Bool ?? true
        rainAlerts = defaults.bool(forKey: Key.rainAlerts)
        navigationEngine = defaults.string(forKey: Key.navigationEngine).flatMap(RideEngine.Engine.init(rawValue:))
            ?? .matched
        syncPasswordsToICloud = defaults.object(forKey: Key.syncPasswords) as? Bool ?? true
        // didSet doesn't run in init: bring already-stored passwords in line (one-time migration).
        KeychainStore.applySync(syncPasswordsToICloud)
    }

    /// Unit formatter bound to the current units setting.
    var unitFormat: UnitFormat { UnitFormat(units: units) }

    /// Normalised base URL, if the stored string parses to an http(s) URL.
    var serverURL: URL? { AppSettings.normalize(serverURLString) }

    func completeOnboarding(useServer: Bool) {
        self.useServer = useServer
        self.hasCompletedOnboarding = true
    }

    /// Re-show onboarding (used from Settings to switch modes).
    func resetOnboarding() { hasCompletedOnboarding = false }

    /// Accept "host:port", "http://host:port", trailing slashes, etc. Defaults to http:// for a
    /// bare host (self-hosted servers are usually plain-HTTP on the LAN).
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.scheme == "http" || url.scheme == "https", url.host != nil
        else { return nil }
        return url
    }
}

/// What the first (tappable) metric of the Navigating panel shows.
enum NavPrimaryMetric: String, CaseIterable, Identifiable {
    case speed, elapsed, remainingGain

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .speed: return "Speed"
        case .elapsed: return "Elapsed time"
        case .remainingGain: return "Climb left"
        }
    }
}

/// A Morse-like tap code on the Halo's touch surface: exactly five short (S) and long (L) taps,
/// like the official app (`TapCodeActivity`). Encoded for the firmware as bit i = tap i was long
/// (`compileCode`).
struct TapCode: Equatable, Hashable {
    static let size = 5

    /// "S"/"L" string, e.g. "SLL".
    let text: String

    init?(_ text: String) {
        let t = text.uppercased()
        guard t.count == Self.size, t.allSatisfy({ $0 == "S" || $0 == "L" }) else { return nil }
        self.text = t
    }

    var bits: UInt8 {
        text.enumerated().reduce(0) { $1.element == "L" ? $0 | (1 << UInt8($1.offset)) : $0 }
    }
    var length: UInt8 { UInt8(text.count) }
    /// "• — —" for display.
    var symbols: String { text.map { $0 == "L" ? "—" : "•" }.joined(separator: " ") }
}

/// What a tap shortcut on the Halo does (the official app's `TouchInputController`).
enum TapAction: String, CaseIterable, Identifiable {
    case horn, clock, battery, light, nothing

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .horn: return "Horn"
        case .clock: return "Show the time"
        case .battery: return "Show the battery"
        case .light: return "Light on / off"
        case .nothing: return "Nothing"
        }
    }

    /// The configurable codes (UP-channel touch strings); "ss" is the firmware's own light toggle.
    /// The Halo reports every code while connected, single taps included (`SensorsTask.c`); the
    /// official app offered • and — too (horn unassigned, clock on —).
    static let codes = ["s", "l", "sl", "ls", "ll", "sss", "lll"]
    static let defaults: [String: TapAction] = ["sl": .horn, "ls": .clock, "ll": .battery]
}

/// The carousel cards the app can feed (all from the Halo or the iPhone, no third-party service).
enum RingCard: CaseIterable, Identifiable {
    case clock, battery, speed, distance, time, avgSpeed

    var id: Self { self }

    var card: Commands.CarouselCard {
        switch self {
        case .clock: return .clock
        case .battery: return .battery
        case .speed: return .speed
        case .distance: return .distance
        case .time: return .time
        case .avgSpeed: return .avgSpeed
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .clock: return "Clock"
        case .battery: return "Battery"
        case .speed: return "Speed"
        case .distance: return "Distance"
        case .time: return "Ride time"
        case .avgSpeed: return "Average speed"
        }
    }

    var systemImage: String {
        switch self {
        case .clock: return "clock"
        case .battery: return "battery.75percent"
        case .speed: return "speedometer"
        case .distance: return "point.topleft.down.to.point.bottomright.curvepath"
        case .time: return "stopwatch"
        case .avgSpeed: return "gauge.with.dots.needle.50percent"
        }
    }

    /// Filled from the iPhone's GPS while riding.
    var isRideMetric: Bool { self != .clock && self != .battery }

    /// Default cards: all of these (the official default minus calories and CO2).
    static let defaultMask: UInt16 = allCases.reduce(0) { $0 | $1.card.bit }
}
