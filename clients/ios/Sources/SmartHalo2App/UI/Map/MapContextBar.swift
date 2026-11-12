import SwiftUI

/// The search pill once a route or destination is in play: its name over `detail` (stats, routing
/// progress, an error), ✕ to drop it. The rest of the pill reopens the search.
struct MapContextPill<Detail: View>: View {
    let title: String
    let closeLabel: LocalizedStringKey
    let onOpen: () -> Void
    let onClose: () -> Void
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.body.weight(.bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    detail()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: Theme.minTarget, height: Theme.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(closeLabel))
        }
        .padding(.leading, Theme.Space.l)
        .padding(.vertical, Theme.Space.xs)
        .frame(minHeight: 60)
        .background(Theme.surface.opacity(0.96),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// Under the pill while a destination is on the map: the kind of route and, when Apple has more than
/// one, which of its routes.
struct RouteOptionsBar: View {
    let profile: RouteProfile
    /// Distance and time of each of Apple's routes.
    let options: [String]
    let choice: Int
    let onProfile: (RouteProfile) -> Void
    let onOption: (Int) -> Void

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(RouteProfile.allCases) { p in
                    chip(selected: p == profile, action: { onProfile(p) }) {
                        Label { Text(p.label) } icon: { Image(systemName: p.systemImage) }
                    }
                }
            }
            if options.count > 1 {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(options.indices, id: \.self) { i in
                        chip(selected: i == choice, action: { onOption(i) }) {
                            Text(verbatim: options[i])
                        }
                    }
                }
            }
        }
    }

    private func chip<Content: View>(selected: Bool, action: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .font(Theme.metricFont(.footnote, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(selected ? Theme.onAccent : Theme.text)
                .padding(.horizontal, Theme.Space.s)
                .frame(maxWidth: .infinity, minHeight: Theme.minTarget)
                .background(selected ? Theme.accent : Theme.surface.opacity(0.94), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.stroke, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The floating actions at the bottom right of the map: ▶ NAVIGATE for a route; for a destination
/// also Compass and Save. Without a route there (no network, no route) only Compass is offered.
struct MapActionRow: View {
    enum Mode: Equatable {
        case route(busy: Bool)
        case destination(routed: Bool, routing: Bool, saved: Bool)
    }

    let mode: Mode
    let onNavigate: () -> Void
    let onCompass: () -> Void
    let onSave: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            switch mode {
            case .route(let busy):
                navigate(enabled: !busy)
            case .destination(let routed, let routing, let saved):
                if routed { save(saved) }
                if routed || routing {
                    compass
                    navigate(enabled: routed)
                } else {
                    Button(action: onCompass) {
                        Label("Compass", systemImage: "location.north.fill").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(MapActionStyle(primary: true))
                }
            }
        }
    }

    private func navigate(enabled: Bool) -> some View {
        Button(action: onNavigate) {
            Label("NAVIGATE", systemImage: "play.fill").labelStyle(.titleAndIcon)
        }
        .buttonStyle(MapActionStyle(primary: true))
        .disabled(!enabled)
    }

    /// Icon only at accessibility text sizes, so the row still fits on the narrowest iPhones.
    @ViewBuilder private var compass: some View {
        if typeSize.isAccessibilitySize {
            Button(action: onCompass) {
                Label("Compass", systemImage: "location.north.fill").labelStyle(.iconOnly)
            }
            .buttonStyle(MapActionStyle(primary: false))
        } else {
            Button("Compass", action: onCompass)
                .buttonStyle(MapActionStyle(primary: false))
        }
    }

    private func save(_ saved: Bool) -> some View {
        Button(action: onSave) {
            Image(systemName: saved ? "star.fill" : "star")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(saved ? Theme.accent : Theme.text)
                .frame(width: Theme.minTargetRiding, height: Theme.minTargetRiding)
                .background(Theme.surface.opacity(0.94), in: Circle())
                .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(saved)
        .accessibilityLabel(Text(saved ? LocalizedStringKey("Saved to my routes")
                                       : LocalizedStringKey("Save to my routes")))
    }
}

/// Capsule button floating on the map: neon for the main action, surface otherwise.
private struct MapActionStyle: ButtonStyle {
    let primary: Bool

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(primary ? .heavy : .bold))
            .lineLimit(1)
            .foregroundStyle(primary ? Theme.onAccent : Theme.text)
            .padding(.horizontal, primary ? 22 : 18)
            .frame(minHeight: Theme.minTargetRiding)
            .background(primary ? Theme.accent : Theme.surface.opacity(0.94), in: Capsule())
            .overlay(Capsule().strokeBorder(primary ? Color.clear : Theme.stroke, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

/// The one message under the top bar; the Map tab picks which by priority.
struct MapNotice: View {
    enum Kind: Equatable {
        case leadingIn
        case importing
        case error(String)
        case locationOff
        case noHalo
        case advice(String)
        case firstRun
    }

    let kind: Kind
    let onOpenSettings: () -> Void
    let onFirstRun: () -> Void

    var body: some View {
        content
            .font(.footnote)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.surface2.opacity(0.96), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .leadingIn:
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text("Finding a route to the start…").foregroundStyle(Theme.textDim)
            }
        case .importing:
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text("Importing the route…").foregroundStyle(Theme.textDim)
            }
        case .error(let message):
            Text(verbatim: message).foregroundStyle(Theme.danger)
        case .locationOff:
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Label("Location is off. Enable it in Settings to navigate.", systemImage: "location.slash")
                    .foregroundStyle(Theme.warn)
                Button("Open Settings", action: onOpenSettings)
                    .font(.footnote.weight(.semibold))
            }
        case .noHalo:
            Label("No Halo: guidance will only show on the phone.", systemImage: "info.circle")
                .foregroundStyle(Theme.textDim)
        case .advice(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.warn)
        case .firstRun:
            Button("Start by searching or importing a GPX", action: onFirstRun)
                .foregroundStyle(Theme.text)
        }
    }
}

/// What stays on the map with the controls hidden: the route or destination in play.
struct MapMiniChip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Theme.metricFont(.footnote, weight: .semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: 32)
            .background(Theme.bg.opacity(0.82), in: Capsule())
            .allowsHitTesting(false)
    }
}

/// One-time hint shown the first time the controls hide.
struct HideControlsHint: View {
    var body: some View {
        Label("Tap the map to show the controls", systemImage: "hand.tap")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.surface2.opacity(0.96), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}
