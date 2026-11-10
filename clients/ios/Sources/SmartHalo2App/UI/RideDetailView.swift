import SwiftUI

/// Detail of a single server ride (M5). The server's ride summary has stats but no track points,
/// so a per-ride GPX export / map isn't possible from this payload (documented deferral).
struct RideDetailView: View {
    let ride: SH2PastRide
    @EnvironmentObject private var settings: AppSettings

    private var fmt: UnitFormat { settings.unitFormat }

    var body: some View {
        List {
            // The server reports metres, seconds and km/h; shown in the rider's units.
            Section("Summary") {
                stat("Date", ride.start ?? ride.stamp ?? ride.createdAt)
                stat("Distance", ride.distance.map { fmt.distance($0) })
                stat("Duration", ride.duration.map { RideClock.string($0) })
                stat("Avg speed", ride.averageSpeed.map { fmt.speed($0 / 3.6) })
                stat("Elevation", ride.elevation.map { fmt.elevation($0) })
                stat("Calories", ride.calories.map { Self.whole($0, UnitEnergy.kilocalories) })
                stat("CO₂ saved", ride.co2.map { Self.whole($0, UnitMass.grams) })
            }
            Section {
                Text("GPX export isn't available: the server's ride summary has no track. To follow routes, import a GPX in Routes.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Ride")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func stat(_ label: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty { LabeledContent(label, value: value) }
    }

    /// "320 kcal", "150 g": the unit as given, no decimals, in the locale's format.
    private static func whole<U: Dimension>(_ value: Double, _ unit: U) -> String {
        Measurement(value: value, unit: unit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}
