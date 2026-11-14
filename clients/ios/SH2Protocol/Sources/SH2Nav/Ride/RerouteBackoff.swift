import Foundation

/// When the "back to the route" request may be tried again after it failed (docs/APP_SPEC.md M17):
/// 30 s after the first failure, twice as long after each one more, up to 8 minutes. Pure: it runs
/// on whatever clock the caller passes, so the same failures give the same waits.
public struct RerouteBackoff: Equatable, Sendable {
    /// The wait after the first failure, seconds.
    public static let initialDelay = 30.0
    /// The wait never grows past this.
    public static let maximumDelay = 480.0

    /// Failures in a row since the last success or reset.
    public private(set) var failures = 0
    /// No attempt before this time (seconds on the caller's clock).
    public private(set) var notBefore = 0.0

    public init() {}

    /// The wait after `failures` failures in a row.
    public static func delay(afterFailures failures: Int) -> Double {
        guard failures > 0 else { return 0 }
        return min(maximumDelay, initialDelay * pow(2, Double(failures - 1)))
    }

    public func canAttempt(at time: Double) -> Bool { time >= notBefore }

    /// An attempt failed at `time`: the next waits `delay(afterFailures:)`.
    public mutating func failed(at time: Double) {
        failures += 1
        notBefore = time + Self.delay(afterFailures: failures)
    }

    /// An attempt succeeded, or the rider is back on the route: start over.
    public mutating func reset() {
        failures = 0
        notBefore = 0
    }
}
