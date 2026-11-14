import SwiftUI
import SwiftData
import MapKit

/// Route detail (UX_DESIGN §4.4): map of the route, name + source, stats grid (distance, ↗ climb,
/// ↘ descent, ETA), elevation profile (only with `<ele>`), share .gpx, and ▶ NAVEGAR — which selects
/// the route, switches to the Map tab and starts Navigating (`RouteSelection.select(…, navigate:)`).
struct RouteDetailView: View {
    let routeID: UUID

    @EnvironmentObject private var library: RouteLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss

    @Query private var matches: [SavedRoute]

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDelete = false
    @State private var loadError = false
    @State private var show3D = false
    /// The MapLibre map's layers (Settings › Advanced › Map engine), shared with the Map tab.
    @AppStorage(MapLayerSelection.storageKey) private var layers = MapLayerSelection()

    init(routeID: UUID) {
        self.routeID = routeID
        _matches = Query(filter: #Predicate<SavedRoute> { $0.id == routeID })
    }

    private var fmt: UnitFormat { settings.unitFormat }

    var body: some View {
        Group {
            if let saved = matches.first, let route = library.route(for: saved) {
                detail(saved, route)
            } else {
                EmptyState(systemImage: "exclamationmark.triangle",
                           title: "Route not available",
                           message: "This route was deleted or its file can't be read.",
                           tint: Theme.warn)
            }
        }
        .haloScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ saved: SavedRoute, _ route: GPXRoute) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                routeMap(route)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1))
                .accessibilityLabel(Text("Map of the route"))
                .overlay(alignment: .topTrailing) {
                    Button { show3D = true } label: {
                        Label("3D", systemImage: "mountain.2.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, Theme.Space.m)
                            .frame(minHeight: Theme.minTarget)
                            .background(Theme.accent, in: Capsule())
                    }
                    .padding(Theme.Space.s)
                    .accessibilityLabel(Text("View the route in 3D"))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: saved.name)
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(Theme.text)
                    Text(verbatim: saved.sourceLabel)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                }

                stats(saved)

                if route.hasElevation {
                    ElevationProfileView(route: route, fmt: fmt)
                        .haloCard()
                }

                if loadError {
                    Text("Couldn't read this route's GPX file.")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                }
            }
            .padding(Theme.Space.l)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Theme.Space.s) {
                PrimaryButton("NAVIGATE", systemImage: "play.fill") {
                    loadError = !library.select(saved, navigate: true)
                }
                Button("Show on map") {
                    if library.select(saved) { router.tab = .map } else { loadError = true }
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: Theme.minTarget)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .background(Theme.bg)
        }
        .navigationTitle(Text(verbatim: saved.name))
        .fullScreenCover(isPresented: $show3D) {
            Route3DView(route: route, fmt: fmt) { show3D = false }
                .haloTheme()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(item: library.shareFile(for: saved), preview: SharePreview(saved.name)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(Text("Share GPX"))
                Menu {
                    Button {
                        renameText = saved.name
                        showRename = true
                    } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { showDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text("Route options"))
            }
        }
        .alert("Rename route", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") { library.rename(saved, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this route?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                dismiss()
                library.delete(saved)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: saved.name)
        }
    }

    /// The route on the map engine of Settings: a still MapLibre map, or MapKit's.
    @ViewBuilder private func routeMap(_ route: GPXRoute) -> some View {
        if settings.mapEngine == .mapLibre {
            HaloMapView(layers: layers, content: HaloMapContent(route: route),
                        move: HaloMapMove(.frame(route.points), animated: false),
                        interactive: false, allowsPitch: false)
                .overlay(alignment: .bottomLeading) {
                    MapAttributionBar(layers: layers).padding(Theme.Space.s)
                }
        } else {
            Map(initialPosition: .rect(route.boundingMapRect(padding: 0.12))) {
                RouteMapLayers.route(route)
            }
            .mapStyle(.halo)
        }
    }

    private func stats(_ saved: SavedRoute) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.s),
                            GridItem(.flexible(), spacing: Theme.Space.s)],
                  spacing: Theme.Space.s) {
            statTile { MetricView(fmt.distanceParts(saved.distance), label: "distance", size: .medium) }
            statTile {
                MetricView(value: "~" + fmt.duration(saved.estimatedDuration), label: "estimated", size: .medium)
            }
            if let gain = saved.gain {
                statTile {
                    MetricView(value: "↗ " + fmt.elevationParts(gain).value, unit: fmt.elevationParts(gain).unit,
                               label: "climb", size: .medium)
                }
            }
            if let loss = saved.loss {
                statTile {
                    MetricView(value: "↘ " + fmt.elevationParts(loss).value, unit: fmt.elevationParts(loss).unit,
                               label: "descent", size: .medium)
                }
            }
        }
    }

    private func statTile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .haloCard(padding: Theme.Space.m)
    }
}
