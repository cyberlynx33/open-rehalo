import SwiftUI

/// Rides history pulled from the self-hosted server (`GET /api/v1/users/rides`).
struct RidesView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var auth: AuthStore
    @State private var rides: [SH2PastRide] = []
    @State private var loading = false
    @State private var error: String?

    private var fmt: UnitFormat { settings.unitFormat }

    var body: some View {
        List {
            if loading { HStack { ProgressView(); Text("Loading…") } }
            if let error { Text(verbatim: error).foregroundStyle(.red).font(.footnote) }
            if !loading && error == nil && rides.isEmpty {
                Text("No rides yet.").foregroundStyle(.secondary)
            }
            ForEach(rides) { ride in
                NavigationLink {
                    RideDetailView(ride: ride)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: ride.start ?? ride.stamp ?? String(localized: "Ride \(ride.id ?? 0)"))
                            .font(.headline)
                        // The server reports metres, seconds and km/h; shown in the rider's units.
                        HStack(spacing: 14) {
                            if let metres = ride.distance { Text(verbatim: fmt.distance(metres)) }
                            if let seconds = ride.duration { Text(verbatim: fmt.duration(seconds)) }
                            if let kmh = ride.averageSpeed { Text(verbatim: fmt.speed(kmh / 3.6)) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Rides")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let url = AppSettings.shared.serverURL, TokenStore.load(.access) != nil else {
            error = String(localized: "Not signed in."); return
        }
        loading = true; error = nil
        defer { loading = false }
        // Through `authorized`: the access token lasts an hour, and an expired one is refreshed
        // and the call retried instead of the list failing with a 401.
        do { rides = try await auth.authorized { jwt in try await SH2Server(baseURL: url).rides(accessJWT: jwt) } }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}
