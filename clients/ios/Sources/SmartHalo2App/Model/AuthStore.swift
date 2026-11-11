import Foundation
import Combine

/// Holds the server-session state (logged-in user + JWTs) and drives login/signup/logout against a
/// self-hosted `sh2-server`. Tokens live in the Keychain (`TokenStore`); the public user is cached in
/// UserDefaults so the account shows instantly on launch.
@MainActor
final class AuthStore: ObservableObject {
    static let shared = AuthStore()

    @Published private(set) var user: SH2User?
    @Published var busy = false
    @Published var lastError: String?

    private let userDefaultsKey = "sh2.user"

    var isLoggedIn: Bool { user != nil && TokenStore.load(.access) != nil }

    private init() { restore() }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let u = try? JSONDecoder().decode(SH2User.self, from: data) else { return }
        user = u
    }

    @discardableResult
    func login(serverURL: URL, email: String, password: String) async -> Bool {
        await run {
            let resp = try await SH2Server(baseURL: serverURL).login(email: email, password: password)
            self.persist(serverURL: serverURL, resp: resp)
        }
    }

    @discardableResult
    func signup(serverURL: URL, email: String, password: String,
                firstName: String, lastName: String) async -> Bool {
        await run {
            let resp = try await SH2Server(baseURL: serverURL)
                .signup(email: email, password: password, firstName: firstName, lastName: lastName)
            self.persist(serverURL: serverURL, resp: resp)
        }
    }

    /// Re-fetch the account from the server (also a cheap connectivity check). An expired access
    /// token is refreshed on the way; a session the server no longer accepts ends in a logout, so
    /// the account isn't shown as connected when it isn't.
    func refreshProfile() async {
        guard let url = AppSettings.shared.serverURL else { return }
        do {
            let u = try await authorized { jwt in try await SH2Server(baseURL: url).whoami(accessJWT: jwt) }
            user = u
            cache(u)
        } catch {
            // Offline or a server error: keep the cached account.
        }
    }

    /// Run a call that needs the access token. On 401 the tokens are refreshed once with the refresh
    /// token and the call retried; if the server rejects the refresh too, the session is over and
    /// the account is logged out. Throws when nobody is logged in.
    func authorized<T>(_ call: (String) async throws -> T) async throws -> T {
        guard let access = TokenStore.load(.access) else { throw SH2ServerError.http(401, "not logged in") }
        do {
            return try await call(access)
        } catch SH2ServerError.http(401, _) {
            guard let url = AppSettings.shared.serverURL, let refresh = TokenStore.load(.refresh) else {
                logout()
                throw SH2ServerError.http(401, "session expired")
            }
            let tokens: SH2Tokens
            do {
                tokens = try await SH2Server(baseURL: url).refresh(refreshJWT: refresh)
            } catch SH2ServerError.http(let code, _) where code == 401 || code == 403 {
                logout()
                throw SH2ServerError.http(code, "session expired")
            }
            TokenStore.save(tokens.access_jwt, .access)
            TokenStore.save(tokens.refresh_jwt, .refresh)
            return try await call(tokens.access_jwt)
        }
    }

    func logout() {
        user = nil
        TokenStore.clear()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    // MARK: - Helpers

    private func run(_ work: @escaping () async throws -> Void) async -> Bool {
        busy = true; lastError = nil
        defer { busy = false }
        do { try await work(); return true }
        catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private func persist(serverURL: URL, resp: SH2AuthResponse) {
        TokenStore.save(resp.access_jwt, .access)
        TokenStore.save(resp.refresh_jwt, .refresh)
        AppSettings.shared.serverURLString = serverURL.absoluteString
        if let u = resp.user { user = u; cache(u) }
    }

    private func cache(_ u: SH2User) {
        if let data = try? JSONEncoder().encode(u) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }
}
