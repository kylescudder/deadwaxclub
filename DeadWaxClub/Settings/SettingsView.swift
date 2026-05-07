import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage("appearance") private var appearance: Appearance = .system
    @State private var discogsToken: String = ""
    @State private var savedDiscogsBanner = false
    @State private var showSignOutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showFinalDeleteConfirm = false
    @State private var deleteError: String?
    @State private var isDeleting = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Profile") {
                if let profile = services.profile.profile {
                    HStack {
                        Text("Display name")
                        Spacer()
                        Text(profile.displayName ?? "Not set")
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                NavigationLink("Edit display name") {
                    EditDisplayNameView(initial: services.profile.profile?.displayName ?? "")
                }
            }

            Section {
                NotificationSettingsRow()
            } header: {
                Text("Notifications")
            } footer: {
                Text("Get a push when a wishlist record's price hits a new low.")
            }

            Section {
                SecureField("Personal access token", text: $discogsToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save token") {
                    services.discogs.setToken(discogsToken)
                    savedDiscogsBanner = true
                    services.evaluateOnboarding()
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
                Text("Used for barcode lookups, cover art, artist, colour way, and estimated marketplace value. Get a token at discogs.com/settings/developers.")
            }

            Section("Account") {
                if case let .signedIn(_, email) = services.auth.state, let email {
                    LabeledContent("Signed in as", value: email)
                }
                Button("Sign out", role: .destructive) {
                    showSignOutConfirm = true
                }
                Button("Delete account", role: .destructive) {
                    showDeleteConfirm = true
                }
                .disabled(isDeleting)
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Link("View Dead Wax Club on GitHub", destination: URL(string: "https://github.com/kylescudder/deadwaxclub")!)
            }
        }
        .navigationTitle("Settings")
        .alert("Saved", isPresented: $savedDiscogsBanner) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Discogs token stored securely in the keychain.")
        }
        .confirmationDialog("Sign out of Dead Wax Club?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task {
                    await services.auth.signOut()
                    await services.sync.wipe()
                    services.onboarding.resetForSignOut()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete your Dead Wax Club account?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) {
                showFinalDeleteConfirm = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes your collection, lists, prices, devices, and account. This cannot be undone.")
        }
        .alert(
            "Are you absolutely sure?",
            isPresented: $showFinalDeleteConfirm
        ) {
            Button("Delete forever", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All your data will be deleted immediately.")
        }
        .alert("Couldn't delete account", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        ), presenting: deleteError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await services.auth.deleteAccount()
            Haptics.success()
        } catch {
            deleteError = error.localizedDescription
            Haptics.error()
        }
    }
}

private struct NotificationSettingsRow: View {
    @ObservedObject private var push = PushManager.shared

    var body: some View {
        switch push.authorizationStatus {
        case .authorized, .ephemeral, .provisional:
            Label("Allowed", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .denied:
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label("Disabled in iOS Settings", systemImage: "xmark.seal")
                    .foregroundStyle(.red)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        case .notDetermined:
            Button("Turn on price-alert notifications") {
                Task { await push.requestAuthorization() }
            }
        @unknown default:
            Text("Unknown")
        }
    }
}

private struct EditDisplayNameView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var didSeed = false
    @State private var isSaving = false

    init(initial: String) {
        self._name = State(initialValue: initial)
        self._didSeed = State(initialValue: !initial.isEmpty)
    }

    var body: some View {
        Form {
            TextField("Display name", text: $name)
                .textContentType(.name)
        }
        .navigationTitle("Display name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        isSaving = true
                        await services.profile.updateDisplayName(name.trimmingCharacters(in: .whitespaces))
                        isSaving = false
                        Haptics.success()
                        dismiss()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        }
        // Seed the field from the profile the first time a non-empty value
        // is available — covers the race where NavigationLink built this
        // view before the profile watcher had emitted, or where the parent
        // Settings view rendered while profile was still nil.
        .task(id: services.profile.profile?.displayName) {
            if !didSeed, let value = services.profile.profile?.displayName, !value.isEmpty {
                name = value
                didSeed = true
            }
        }
    }
}
