import SwiftUI

/// Enter a self-hosted `sh2-server` URL and log in or sign up. Calls `onSuccess` once authenticated.
struct LoginView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    /// Called after a successful login/signup. For onboarding this completes onboarding; from Settings
    /// it just dismisses.
    var onSuccess: () -> Void

    enum Mode: CaseIterable {
        case login, signup

        /// Segment and button title, through the String Catalog.
        var label: LocalizedStringKey {
            switch self {
            case .login: return "Log in"
            case .signup: return "Sign up"
            }
        }
    }
    @State private var mode: Mode = .login
    @State private var serverURL: String = AppSettings.shared.serverURLString
    @State private var email = ""
    @State private var password = ""
    @State private var firstName = ""
    @State private var lastName = ""

    private var urlValid: Bool { AppSettings.normalize(serverURL) != nil }
    private var canSubmit: Bool {
        urlValid && !email.isEmpty && password.count >= 4 && !auth.busy
            && (mode == .login || (!firstName.isEmpty))
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("http://your-server:8730", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if !serverURL.isEmpty && !urlValid {
                    Text("Enter a valid http(s) URL or host:port").font(.caption).foregroundStyle(Theme.danger)
                }
            }

            Section {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section(mode == .login ? "Credentials" : "New account") {
                if mode == .signup {
                    TextField("First name", text: $firstName).textContentType(.givenName)
                    TextField("Last name", text: $lastName).textContentType(.familyName)
                }
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                SecureField("Password", text: $password)
            }

            if let err = auth.lastError {
                Section { Text(verbatim: err).foregroundStyle(Theme.danger).font(.footnote) }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if auth.busy { ProgressView() }
                        Text(mode.label).frame(maxWidth: .infinity)
                    }
                }
                .disabled(!canSubmit)
            }
        }
        .navigationTitle("Connect to a server")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() async {
        guard let url = AppSettings.normalize(serverURL) else { return }
        let ok: Bool
        switch mode {
        case .login:
            ok = await auth.login(serverURL: url, email: email, password: password)
        case .signup:
            ok = await auth.signup(serverURL: url, email: email, password: password,
                                   firstName: firstName, lastName: lastName)
        }
        if ok { onSuccess(); dismiss() }
    }
}
