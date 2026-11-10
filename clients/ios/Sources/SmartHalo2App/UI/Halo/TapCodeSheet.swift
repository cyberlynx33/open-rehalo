import SwiftUI

/// Define the alarm's tap code (the official app's "Define Tapcode", `TapCodeActivity`): five
/// short and long taps — a tap or a long press on the pad, or tapped on the Halo itself — sent to
/// the Halo as soon as the fifth one is in, and saved only if the Halo accepts it. Needs the Halo
/// connected. The code arms and disarms the alarm on the Halo when no phone is connected, e.g.
/// with a flat iPhone battery.
struct TapCodeSheet: View {
    /// Live controller (nil = not connected: the code can't be changed).
    var controller: DeviceController?

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var connection: HaloConnection
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""
    @State private var saving = false
    @State private var failed = false
    @State private var saved = false

    /// Connected right now, not only when the sheet opened: a Halo that drops meanwhile disables the pad.
    private var isConnected: Bool { controller != nil && connection.state == .connected }
    private var canEdit: Bool { isConnected && !saving }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Define tap code")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(Theme.text)
                Text("Your tap code lets you arm and disarm the alarm should your phone run out of battery. Just tap the Morse-like code on the Halo's touch surface.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
            }

            slots

            pad

            if !isConnected {
                Label("Connect to your Halo to change the tap code.", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.footnote)
                    .foregroundStyle(Theme.warn)
            } else if saving {
                HStack(spacing: Theme.Space.s) {
                    ProgressView()
                    Text("Changing your tap code…").foregroundStyle(Theme.textDim)
                }
                .font(.footnote)
            } else if failed {
                Label("An error occurred while setting your tap code. Please try again.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.warn)
            } else {
                Label("Tap the pad for a short tap, press and hold for a long one — or tap it on the Halo.", systemImage: "hand.tap")
                    .font(.footnote)
                    .foregroundStyle(Theme.textDim)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Space.xl)
        .sensoryFeedback(.success, trigger: saved)
        .sensoryFeedback(.error, trigger: failed) { _, new in new }
        .onAppear {
            controller?.tapCaptured = { code in
                guard canEdit else { return }
                entry = String(code.uppercased().prefix(TapCode.size))
                submitIfComplete()
            }
        }
        .onDisappear { controller?.tapCaptured = nil }
    }

    /// The five taps: filled as they come in, the saved code until then.
    private var slots: some View {
        let shown = entry.isEmpty && !failed ? (settings.alarmTapCode?.text ?? "") : entry
        return HStack(spacing: Theme.Space.m) {
            ForEach(0..<TapCode.size, id: \.self) { i in
                let symbol: Character? = i < shown.count ? shown[shown.index(shown.startIndex, offsetBy: i)] : nil
                Capsule()
                    .fill(symbol == nil ? Theme.surface : (entry.isEmpty ? Theme.textDim : Theme.accent))
                    .frame(width: symbol == "L" ? 40 : 14, height: 14)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(minHeight: 64)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .animation(.snappy, value: entry)
        .accessibilityElement()
        .accessibilityLabel(Text("Tap code"))
        .accessibilityValue(Text(verbatim: shown.isEmpty ? "—" : (TapCode(shown)?.symbols ?? shown)))
    }

    /// The official "TAP HERE" pad: tap = short, press and hold = long.
    private var pad: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 44, weight: .semibold))
            Text("Tap here")
                .font(.headline.weight(.heavy))
        }
        .foregroundStyle(canEdit ? Theme.accent : Theme.textDim)
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(canEdit ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onTapGesture { add("S") }
        .onLongPressGesture(minimumDuration: 0.4) { add("L") }
        .allowsHitTesting(canEdit)
        .accessibilityElement()
        .accessibilityLabel(Text("Tap pad"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Short tap")) { add("S") }
        .accessibilityAction(named: Text("Long tap")) { add("L") }
    }

    private func add(_ symbol: Character) {
        guard canEdit else { return }
        if failed { failed = false; entry = "" }
        guard entry.count < TapCode.size else { return }
        entry.append(symbol)
        submitIfComplete()
    }

    /// Five taps in: send the code to the Halo; keep it only if the Halo accepts it.
    private func submitIfComplete() {
        guard let controller, let code = TapCode(entry), !saving else { return }
        saving = true
        failed = false
        Task {
            let ok = await controller.applyAlarmConfig(tapCode: code)
            saving = false
            if ok {
                saved = true
                try? await Task.sleep(for: .milliseconds(500))
                dismiss()
            } else {
                failed = true
            }
        }
    }
}
