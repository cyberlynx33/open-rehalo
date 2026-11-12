import SwiftUI

/// Settings › Advanced › Sound & touch (the sound/touch part of the old M2 Security screen; the
/// alarm controls moved to the Halo tab card and Settings › Alarm). Post-MVP: own redesigned screen.
struct SoundTouchView: View {
    @ObservedObject var controller: DeviceController
    @AppStorage(DeviceController.touchSoundsKey) private var touchSounds = true

    var body: some View {
        List {
            Section("Sound") {
                Button { Task { await controller.playSound() } } label: {
                    Label("Play sound", systemImage: "speaker.wave.2")
                }
                Button { Task { await controller.stopSound() } } label: {
                    Label("Stop sound", systemImage: "speaker.slash")
                }
                Toggle(isOn: Binding(
                    get: { touchSounds },
                    set: { v in touchSounds = v; Task { await controller.setTouchSounds(on: v) } }
                )) {
                    Label("Touch sounds", systemImage: "hand.tap")
                }
            }
            .listRowBackground(Theme.surface)

            Section {
                Button { Task { await controller.runTouchOnboarding() } } label: {
                    Label("Touch onboarding animation", systemImage: "hand.point.up.left")
                }
            } header: {
                Text("Touch")
            } footer: {
                Text("Sound and touch need a connected (re-paired) Halo.")
            }
            .listRowBackground(Theme.surface)
        }
        .disabled(controller.phase != .ready)
        .haloListStyle()
        .navigationTitle("Sound & touch")
        .navigationBarTitleDisplayMode(.inline)
    }
}
