import SwiftUI
import SH2Protocol

/// "Display & ring" screen — drives every service-1 display widget/animation (M1). The carousel
/// lives in Halo › Ring cards. All actions are fire-and-forget BLE commands through `DeviceController`.
struct DisplayView: View {
    @ObservedObject var controller: DeviceController

    @State private var heading: Double = 0     // 0…359°
    @State private var progress: Double = 50    // 0…100 %
    @State private var frontExternal = false

    var body: some View {
        List {
            widgetsSection
            compassSection
            progressSection
            introsSection
            frontLightSection
            Section {
                Button(role: .cancel) { Task { await controller.animationsOff() } } label: {
                    Label("Animations off", systemImage: "stop.circle")
                }
            }
        }
        .navigationTitle("Display & ring")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var widgetsSection: some View {
        Section("Widgets") {
            actionRow("Clock", "clock") { await controller.showClockNow() }
            actionRow("Clock off", "clock.badge.xmark") { await controller.clockOff() }
            actionRow("Speedometer", "speedometer") { await controller.showSpeedometerDemo() }
            actionRow("Speedometer off", "gauge.with.dots.needle.0percent") { await controller.speedometerOff() }
            actionRow("Battery", "battery.100") { await controller.showCharge() }
            actionRow("Heartbeat", "heart") { await controller.showHeartbeat() }
            actionRow("Heartbeat off", "heart.slash") { await controller.heartbeatOff() }
            actionRow("Logo", "seal") { await controller.showLogo() }
            actionRow("Low-battery warning", "battery.25") { await controller.showLowBattery() }
            actionRow("Demo", "wand.and.stars") { await controller.showDemo() }
        }
    }

    private var compassSection: some View {
        Section("Compass") {
            VStack(alignment: .leading) {
                Text("Heading: \(Int(heading))°")
                Slider(value: $heading, in: 0...359, step: 1)
            }
            actionRow("Point to heading", "location.north.line") {
                await controller.showCompass(heading: UInt16(heading))
            }
            actionRow("Compass off", "location.slash") { await controller.compassOff() }
        }
    }

    private var progressSection: some View {
        Section("Progress ring") {
            VStack(alignment: .leading) {
                Text("Progress: \(Int(progress))%")
                Slider(value: $progress, in: 0...100, step: 1)
            }
            actionRow("Show progress", "circle.dashed") { await controller.showProgress(UInt8(progress)) }
            actionRow("Progress off", "circle.slash") { await controller.progressOff() }
        }
    }

    private var introsSection: some View {
        Section("Intro animations") {
            actionRow("Speedometer intro", "play.circle") { await controller.showSpeedometerIntro() }
            actionRow("Fitness intro", "figure.run") { await controller.showFitnessIntro() }
        }
    }

    private var frontLightSection: some View {
        Section("Front light") {
            Toggle("External (handlebar) light", isOn: $frontExternal)
                .onChange(of: frontExternal) { _, on in
                    Task { await controller.setFrontExternal(on: on) }
                }
        }
    }

    /// A `LocalizedStringKey` title, so the row goes through the String Catalog (a `String` would not).
    private func actionRow(_ title: LocalizedStringKey, _ icon: String,
                           _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Label(title, systemImage: icon) }
    }
}
