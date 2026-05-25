import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage(Preferences.currencyKey) private var currency: String = Preferences.localeCurrency
    @State private var discogsToken: String = ""
    @State private var savedDiscogsBanner = false
    @State private var showSignOutConfirm = false
    @State private var showPaywall = false
    @State private var showDeleteConfirm = false
    @State private var showFinalDeleteConfirm = false
    @State private var deleteError: String?
    @State private var isDeleting = false
    @State private var successCount = 0
    @State private var errorCount = 0

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                Picker("Currency", selection: $currency) {
                    ForEach(Preferences.pickableCurrencies, id: \.self) { code in
                        Text(Preferences.displayName(for: code)).tag(code)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Currency")
            } footer: {
                Text("Default for new prices you log. Existing entries keep whatever currency they were saved in. Discogs estimates display in the currency set on your Discogs account (discogs.com → Settings → My Buyer Settings) — change it there if estimates show up in the wrong currency.")
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
                NavigationLink {
                    ManageCollectionsView()
                } label: {
                    HStack {
                        Label("Sharing", systemImage: "person.2.circle")
                        Spacer()
                        Text("\(services.collections.collections.count)")
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            } header: {
                Text("Collections")
            } footer: {
                Text("Share your owned/wishlist with people you trust. They see (and can add to) the same pool — no manual list-copying.")
            }

            Section {
                NotificationSettingsRow()
            } header: {
                Text("Notifications")
            } footer: {
                Text("Get a push when a wishlist record's price hits a new low.")
            }

            Section {
                LabeledContent(
                    "Plan",
                    value: services.billing.isSubscribed ? "Supporter Monthly" : "Free"
                )
                if services.billing.isSubscribed {
                    Button("Manage subscription") {
                        Task { await services.billing.manageSubscriptions() }
                    }
                } else {
                    Button("Subscribe") {
                        showPaywall = true
                    }
                }
                Button("Restore purchases") {
                    Task { await services.billing.restorePurchases() }
                }
                if let message = services.billing.lastError {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Subscription")
            } footer: {
                Text("Free accounts can add up to \(AppServices.freeRecordLimit) records. Manage subscription opens Apple's system sheet, where you can cancel or change the subscription.")
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Used for barcode lookups, cover art, artist, colour way, and estimated marketplace value.")
                    Link("Get a Discogs developer token", destination: URL(string: "https://www.discogs.com/settings/developers")!)
                }
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
                Link("View Deadwax Club on GitHub", destination: URL(string: "https://github.com/kylescudder/deadwaxclub")!)
            }
        }
        .navigationTitle("Settings")
        .alert("Saved", isPresented: $savedDiscogsBanner) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Discogs token stored securely in the keychain.")
        }
        .sheet(isPresented: $showPaywall) {
            SubscriptionPaywallView()
        }
        .alert("Sign out of Deadwax Club?", isPresented: $showSignOutConfirm) {
            Button("Sign out", role: .destructive) {
                Task {
                    await services.auth.signOut()
                    await services.sync.wipe()
                    services.onboarding.resetForSignOut()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Delete your Deadwax Club account?",
            isPresented: $showDeleteConfirm
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
        .sensoryFeedback(.success, trigger: successCount)
        .sensoryFeedback(.error, trigger: errorCount)
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
            successCount += 1
        } catch {
            deleteError = error.localizedDescription
            errorCount += 1
        }
    }
}

private struct NotificationSettingsRow: View {
    @ObservedObject private var push = PushManager.shared
    @Environment(\.openURL) private var openURL

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
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
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
    @State private var saveCount = 0

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
                        saveCount += 1
                        dismiss()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        }
        .sensoryFeedback(.success, trigger: saveCount)
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
