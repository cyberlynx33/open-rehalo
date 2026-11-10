import SwiftUI

/// "Fitness" screen (M5): set a distance goal and preview the progress ring on the device.
/// Live GPS ride recording (auto-tracking toward the goal) is deferred — see docs/APP_SPEC.md M5.
struct FitnessView: View {
    @ObservedObject var controller: DeviceController
    @EnvironmentObject private var settings: AppSettings
    /// Stored in kilometres whatever the units setting; shown through `UnitFormat`.
    @AppStorage("sh2.fitness.goalKm") private var goalKm: Double = 20
    @AppStorage("sh2.fitness.doneKm") private var doneKm: Double = 0

    private var fmt: UnitFormat { settings.unitFormat }
    private var progress: Double { goalKm > 0 ? min(1, doneKm / goalKm) : 0 }
    private var percent: Int { Int((progress * 100).rounded()) }

    var body: some View {
        List {
            Section("Goal") {
                VStack(alignment: .leading) {
                    Text("Daily goal: \(fmt.distance(goalKm * 1000))")
                    Slider(value: $goalKm, in: 5...100, step: 5)
                }
                VStack(alignment: .leading) {
                    Text("Done: \(fmt.distance(doneKm * 1000)) · \(percent)%")
                    Slider(value: $doneKm, in: 0...max(goalKm, 5), step: 0.5)
                }
                ProgressView(value: progress)
            }

            Section("Show on the ring") {
                Button { Task { await controller.showProgress(UInt8(progress * 100)) } } label: {
                    Label("Preview progress ring", systemImage: "circle.dashed")
                }
                Button { Task { await controller.showFitnessIntro() } } label: {
                    Label("Fitness intro", systemImage: "figure.run")
                }
                Button(role: .cancel) { Task { await controller.progressOff() } } label: {
                    Label("Clear", systemImage: "stop.circle")
                }
            }

            Section {
                Text("Live GPS ride recording (auto-tracking distance toward your goal) isn't implemented yet — set progress manually for now.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Fitness")
        .navigationBarTitleDisplayMode(.inline)
    }
}
