import SwiftUI

/// Presented by RootView whenever AuthClient.isPasswordRecovery flips true —
/// i.e. the user just opened a recovery link and Supabase has handed us a
/// recovery session. The sheet is interactive-dismiss-disabled so the user
/// either sets a new password or explicitly signs out; we don't want to leave
/// them stranded in the app on a recovery session they can't escape.
struct ResetPasswordSheet: View {
    @EnvironmentObject private var services: AppServices

    @State private var password = ""
    @State private var confirm = ""
    @State private var isWorking = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Text("Choose a new password to finish signing in.")
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)

                    SecureField("New password", text: $password)
                        .textContentType(.newPassword)
                        .padding()
                        .background(Theme.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                    SecureField("Confirm new password", text: $confirm)
                        .textContentType(.newPassword)
                        .padding()
                        .background(Theme.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                    if let error = localError ?? services.auth.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    PrimaryButton(title: "Save new password", isLoading: isWorking) {
                        Task { await save() }
                    }
                    .disabled(!isFormValid || isWorking)
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.Colors.background)
            .navigationTitle("Set a new password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign out") {
                        Task {
                            if await services.auth.signOut() {
                                await services.sync.wipe()
                                services.auth.isPasswordRecovery = false
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .interactiveDismissDisabled()
        }
    }

    private var isFormValid: Bool {
        password.count >= 6 && password == confirm
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }
        localError = nil
        guard password == confirm else {
            localError = "Passwords don't match."
            return
        }
        await PasswordRecoveryCleanup.run(
            updatePassword: { await services.auth.updatePassword(newPassword: password) },
            wipe: { await services.sync.wipe() }
        )
    }
}

enum PasswordRecoveryCleanup {
    @discardableResult
    static func run(
        updatePassword: () async -> Bool,
        wipe: () async -> Void
    ) async -> Bool {
        guard await updatePassword() else { return false }
        await wipe()
        return true
    }
}
