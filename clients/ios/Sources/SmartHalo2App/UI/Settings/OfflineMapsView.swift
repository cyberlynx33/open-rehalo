import SwiftUI

/// Settings › Advanced › Offline maps (docs/APP_SPEC.md M17): the areas saved for the MapLibre map
/// (route corridors and the world basics), their size and state, delete and update, plus the two
/// download settings.
struct OfflineMapsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = OfflineMapStore.shared

    var body: some View {
        List {
            if settings.mapEngine != .mapLibre {
                Section {
                    Label("Offline maps work with the MapLibre map engine (Advanced › Map engine).",
                          systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Theme.textDim)
                }
                .listRowBackground(Theme.surface)
            }

            Section {
                Toggle(isOn: $settings.offlineWiFiOnly) {
                    Label("Wi-Fi only", systemImage: "wifi")
                }
                Toggle(isOn: $settings.offlineSaveWithRoute) {
                    Label("Save the map with each route", systemImage: "map")
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("A 1 km corridor around each saved route, zoom 1 to 14, plus the world at zoom 0 and 1 so the map's style, fonts and icons work without a connection.")
            }
            .tint(Theme.accent)
            .listRowBackground(Theme.surface)

            Section {
                if store.areas.isEmpty {
                    Text("No areas yet. Save a route with the setting above on, or download the world basics.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textDim)
                }
                ForEach(store.areas) { area in
                    row(area)
                        .swipeActions {
                            Button(role: .destructive) { store.remove(area) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { store.update(area) } label: {
                                Label("Update", systemImage: "arrow.clockwise")
                            }
                            .tint(Theme.info)
                        }
                }
                Button {
                    for style in MapBaseStyle.allCases { store.ensureWorldPack(style) }
                } label: {
                    Label("Download the world basics", systemImage: "globe")
                }
            } header: {
                Text("Downloaded areas")
            } footer: {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Swipe an area to delete it or download its changes again.")
                    Text("Map tiles by OpenFreeMap (OpenMapTiles, © OpenStreetMap contributors), whose terms allow up to 3,000 tiles or 50 MB per download. Topo, satellite, relief and cycle layers are not saved offline.")
                    if let error = store.lastError {
                        Text(verbatim: error).foregroundStyle(Theme.warn)
                    }
                }
            }
            .listRowBackground(Theme.surface)
        }
        .haloListStyle()
        .navigationTitle("Offline maps")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { store.reload() }
        .onAppear { store.reload() }
    }

    private func row(_ area: OfflineMapStore.Area) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: area.kind == .world ? "globe" : "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: area.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                HStack(spacing: Theme.Space.xs) {
                    Text(area.style.label)
                    Text(verbatim: "·")
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(area.bytes), countStyle: .file))
                    Text(verbatim: "·")
                    Text("\(area.tiles) tiles")
                }
                .font(.footnote)
                .foregroundStyle(Theme.textDim)
                state(area.state)
            }
            Spacer(minLength: 0)
            if case .downloading(let fraction) = area.state {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .tint(Theme.accent)
            }
        }
    }

    @ViewBuilder private func state(_ state: OfflineMapStore.Area.State) -> some View {
        switch state {
        case .downloading(let fraction):
            Text("Downloading · \(Int((fraction * 100).rounded())) %").font(.footnote).foregroundStyle(Theme.info)
        case .complete:
            Text("Saved").font(.footnote).foregroundStyle(Theme.accent)
        case .paused:
            Text("Paused").font(.footnote).foregroundStyle(Theme.textDim)
        case .waitingForWiFi:
            Text("Waiting for Wi-Fi").font(.footnote).foregroundStyle(Theme.warn)
        case .failed(let message):
            Text(verbatim: message).font(.footnote).foregroundStyle(Theme.danger)
        }
    }
}
