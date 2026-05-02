import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage("appearance") private var appearance: Appearance = .system
    @State private var discogsToken: String = ""
    @State private var savedDiscogsBanner = false
    @State private var showSignOutConfirm = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                SecureField("Personal access token", text: $discogsToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save token") {
                    services.discogs.setToken(discogsToken)
                    savedDiscogsBanner = true
                }
                .disabled(discogsToken.isEmpty)
                if services.discogs.hasToken {
                    Button("Remove token", role: .destructive) {
                        services.discogs.clearToken()
                        discogsToken = ""
                    }
                }
            } header: {
                Text("Discogs API")
            } footer: {
                Text("Used for barcode lookups, cover art, artist and colourway. Get a token at discogs.com/settings/developers.")
            }

            Section("Account") {
                if case let .signedIn(_, email) = services.auth.state, let email {
                    LabeledContent("Signed in as", value: email)
                }
                Button("Sign out", role: .destructive) {
                    showSignOutConfirm = true
                }
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Link("View Trackd on GitHub", destination: URL(string: "https://github.com/kylescudder/trackd")!)
            }
        }
        .navigationTitle("Settings")
        .alert("Saved", isPresented: $savedDiscogsBanner) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Discogs token stored securely in the keychain.")
        }
        .confirmationDialog("Sign out of Trackd?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { await services.auth.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
