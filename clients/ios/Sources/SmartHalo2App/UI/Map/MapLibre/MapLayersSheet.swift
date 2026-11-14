import SwiftUI

/// The MapLibre map's layers, in a sheet (docs/APP_SPEC.md M17): the base (Night / Day), then each
/// overlay with what it is and whom it comes from. Topo and Satellite replace each other.
struct MapLayersSheet: View {
    @Binding var layers: MapLayerSelection
    var onOfflineMaps: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: Theme.Space.m) {
                        ForEach(MapBaseStyle.allCases) { base in
                            baseTile(base)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("Base map")
                } footer: {
                    Text("OpenFreeMap, from OpenStreetMap data.")
                }

                Section {
                    ForEach(MapOverlay.allCases) { overlay in
                        Toggle(isOn: Binding(
                            get: { layers.overlays.contains(overlay) },
                            set: { _ in layers.toggle(overlay) }
                        )) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(overlay.label)
                                    Text(overlay.detail).font(.footnote).foregroundStyle(Theme.textDim)
                                }
                            } icon: {
                                Image(systemName: overlay.systemImage)
                            }
                        }
                        .tint(Theme.accent)
                    }
                } header: {
                    Text("Layers")
                } footer: {
                    Text("Topo and Satellite only cover Spain and replace each other. The cycle network needs a connection.")
                }
                .listRowBackground(Theme.surface)

                if let onOfflineMaps {
                    Section {
                        Button {
                            dismiss()
                            onOfflineMaps()
                        } label: {
                            Label("Offline maps", systemImage: "arrow.down.circle")
                        }
                    }
                    .listRowBackground(Theme.surface)
                }

                Section {
                    ForEach(layers.credits, id: \.self) { credit in
                        Text(verbatim: credit).font(.footnote).foregroundStyle(Theme.textDim)
                    }
                } header: {
                    Text("Map data")
                }
                .listRowBackground(Theme.surface)
            }
            .haloListStyle()
            .navigationTitle("Map layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func baseTile(_ base: MapBaseStyle) -> some View {
        let selected = layers.base == base
        return Button {
            layers.base = base
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(base == .night ? Theme.bg : Color(hex: 0xE8ECE4))
                    .frame(height: 76)
                    .overlay(Image(systemName: base.systemImage)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(base == .night ? Theme.textDim : Color(hex: 0x4A5568)))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.onAccent, Theme.accent)
                                .padding(6)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 3 : 1))
                Text(base.label)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.text)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The credits the MapLibre map owes, in one line over the map (OpenStreetMap's and each layer's
/// source), so they are visible without opening MapLibre's (i) button.
struct MapAttributionBar: View {
    let layers: MapLayerSelection

    var body: some View {
        Text(verbatim: layers.credits.joined(separator: " · "))
            .font(.system(size: 10))
            .foregroundStyle(Theme.textDim)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 3)
            .background(Theme.bg.opacity(0.7), in: Capsule())
            .accessibilityLabel(Text("Map data credits"))
    }
}
