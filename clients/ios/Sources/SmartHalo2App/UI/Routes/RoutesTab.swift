import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Routes tab (UX_DESIGN §4.4): the library of imported GPX routes, last used first. Search, swipe
/// rename / share / delete, (+) import sheet (Files · bundled demo route), and a pushed Route detail.
/// "Open in…" imports land here too (`RouteLibrary.pendingDetail` → detail).
struct RoutesTab: View {
    @EnvironmentObject private var library: RouteLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var selection: RouteSelection

    @Query(sort: \SavedRoute.lastActivity, order: .reverse) private var routes: [SavedRoute]

    @State private var path: [UUID] = []
    @State private var search = ""
    @State private var showImportSheet = false
    @State private var wantsFilePicker = false
    @State private var showImporter = false
    @State private var importError: String?
    @State private var showRename = false
    @State private var renameTarget: SavedRoute?
    @State private var renameText = ""
    @State private var showDelete = false
    @State private var deleteTarget: SavedRoute?

    private var fmt: UnitFormat { settings.unitFormat }

    private var filtered: [SavedRoute] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return routes }
        return routes.filter { $0.name.localizedStandardContains(q) || $0.sourceLabel.localizedStandardContains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .haloScreenBackground()
                .navigationTitle("Routes")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if library.isImporting {
                            ProgressView()
                        } else {
                            Button { showImportSheet = true } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(Theme.onAccent)
                                    .frame(width: 32, height: 32)
                                    .background(Theme.accent, in: Circle())
                            }
                            .accessibilityLabel(Text("Import route"))
                        }
                    }
                }
                .navigationDestination(for: UUID.self) { id in
                    RouteDetailView(routeID: id)
                }
        }
        .sheet(isPresented: $showImportSheet, onDismiss: {
            if wantsFilePicker {
                wantsFilePicker = false
                showImporter = true
            }
        }) {
            ImportRouteSheet(
                onFiles: {
                    wantsFilePicker = true
                    showImportSheet = false
                },
                onDemo: {
                    showImportSheet = false
                    useDemo()
                })
                .presentationDetents([.height(330)])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.surface2)
                .haloTheme()
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.gpx, .xml, .data],
                      allowsMultipleSelection: true) { handleImport($0) }
        .alert("Rename route", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let renameTarget { library.rename(renameTarget, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this route?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleteTarget {
                    path.removeAll { $0 == deleteTarget.id }
                    library.delete(deleteTarget)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: deleteTarget?.name ?? "")
        }
        .onAppear { consumePendingDetail() }
        .onChange(of: library.pendingDetail) { _, _ in consumePendingDetail() }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if routes.isEmpty {
            VStack(spacing: 0) {
                EmptyState(
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    title: "Import your first route",
                    message: "Share a GPX from Wikiloc, Komoot or Strava, or pick one from Files.",
                    primary: .init("Import GPX", systemImage: "square.and.arrow.down") { showImporter = true },
                    secondary: .init("Use demo route", systemImage: "sparkles") { useDemo() })
                if library.isImporting { importingRow.padding(Theme.Space.l) }
                if let importError { errorText(importError).padding(Theme.Space.l) }
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            segment
                .plainRow(top: Theme.Space.s, bottom: Theme.Space.s)
            if library.isImporting {
                importingRow.plainRow()
            }
            if let importError {
                errorText(importError).plainRow()
            }
            ForEach(filtered) { saved in
                row(saved)
            }
            if filtered.isEmpty {
                Text("No routes match “\(search)”.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity)
                    .plainRow(top: Theme.Space.xl)
            }
            Text("To add routes from Wikiloc, Komoot or Strava: Share › \(RouteLibrary.appDisplayName).")
                .font(.footnote)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .plainRow(top: Theme.Space.m, bottom: Theme.Space.xl)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $search, prompt: Text("Search"))
    }

    /// "Routes | Rides · soon" — the Rides history is post-MVP, so its segment is inert.
    private var segment: some View {
        HStack(spacing: 4) {
            Text("Routes")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Theme.stroke, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityAddTraits(.isSelected)
            Text("Rides · soon")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textDim.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: 34)
                .accessibilityHint(Text("Coming in a later version"))
        }
        .padding(3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    private func row(_ saved: SavedRoute) -> some View {
        Button { path.append(saved.id) } label: {
            RouteCard(name: saved.name,
                      subtitle: saved.sourceLabel,
                      distance: fmt.distance(saved.distance),
                      gain: saved.gain.map { fmt.elevation($0) },
                      eta: "~" + fmt.duration(saved.estimatedDuration),
                      thumbnail: library.thumbnailImage(for: saved).map { Image(uiImage: $0) },
                      isSelected: selection.route?.id == saved.id) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .plainRow(top: 6, bottom: 6)
        .task(id: saved.id) { await library.ensureThumbnail(for: saved) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { askDelete(saved) } label: { Label("Delete", systemImage: "trash") }
                .tint(Theme.danger)
            ShareLink(item: library.shareFile(for: saved), preview: SharePreview(saved.name)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(Theme.info)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { askRename(saved) } label: { Label("Rename", systemImage: "pencil") }
                .tint(Theme.warn)
        }
        .contextMenu {
            Button { askRename(saved) } label: { Label("Rename", systemImage: "pencil") }
            ShareLink(item: library.shareFile(for: saved), preview: SharePreview(saved.name)) {
                Label("Share GPX", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) { askDelete(saved) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(verbatim: message)
            .font(.footnote)
            .foregroundStyle(Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// While a GPX is being read and parsed (off the main thread, see `RouteLibrary`).
    private var importingRow: some View {
        HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.small)
            Text("Importing the route…").font(.footnote).foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func askRename(_ saved: SavedRoute) {
        renameTarget = saved
        renameText = saved.name
        showRename = true
    }

    private func askDelete(_ saved: SavedRoute) {
        deleteTarget = saved
        showDelete = true
    }

    private func useDemo() {
        Task {
            if let saved = await library.addDemoRoute() {
                importError = nil
                path = [saved.id]
            } else {
                importError = String(localized: "The demo route isn't available.")
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        let urls: [URL]
        do {
            urls = try result.get()
        } catch {
            importError = String(localized: "Couldn't load GPX: \(error.localizedDescription)")
            return
        }
        Task {
            var imported: [SavedRoute] = []
            var lastError: Error?
            for url in urls {
                do { imported.append(try await library.importGPX(from: url, defaultSource: .files)) } catch { lastError = error }
            }
            importError = lastError.map { String(localized: "Couldn't load GPX: \($0.localizedDescription)") }
            if imported.count == 1, let saved = imported.first { path = [saved.id] }
        }
    }

    private func consumePendingDetail() {
        guard let id = library.pendingDetail else { return }
        library.pendingDetail = nil
        path = [id]
    }
}

/// (+) sheet: import from Files or add the bundled demo route (prototype "Importar ruta").
struct ImportRouteSheet: View {
    let onFiles: () -> Void
    let onDemo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Import route")
                .font(.title3.weight(.heavy))
                .foregroundStyle(Theme.text)
                .padding(.bottom, Theme.Space.xs)
            option("From Files (.gpx)", systemImage: "folder", tint: Theme.info, action: onFiles)
            option("Included demo route", systemImage: "sparkles", tint: Theme.accent, action: onDemo)
            Text("You can also share a .gpx from Wikiloc, Komoot, Strava, Mail or Safari: Share › \(RouteLibrary.appDisplayName).")
                .font(.footnote)
                .foregroundStyle(Theme.textDim)
                .padding(.top, Theme.Space.xs)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func option(_ title: LocalizedStringKey, systemImage: String, tint: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: 56)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    /// A list row without separators/background, with horizontal screen gutters.
    func plainRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: Theme.Space.l, bottom: bottom, trailing: Theme.Space.l))
    }
}
