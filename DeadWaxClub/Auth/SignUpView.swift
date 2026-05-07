import SwiftUI

struct SignUpView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var isWorking = false
    @State private var awaitingConfirmation: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                VStack(spacing: Theme.Spacing.sm) {
                    Text("Create account").font(.largeTitle.weight(.bold))
                    Text("Your collection syncs across devices automatically.")
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, Theme.Spacing.lg)

                if let confirmEmail = awaitingConfirmation {
                    confirmationCard(email: confirmEmail)
                } else {
                    formContent
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Theme.Colors.background)
        .navigationTitle("Sign up")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var formContent: some View {
        VStack(spacing: Theme.Spacing.md) {
            TextField("Display name", text: $displayName)
                .textContentType(.name)
                .padding()
                .background(Theme.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background(Theme.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

            SecureField("Password (min 6 chars)", text: $password)
                .textContentType(.newPassword)
                .padding()
                .background(Theme.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }

        if let error = services.auth.lastError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        PrimaryButton(title: "Create account", isLoading: isWorking) {
            Task { await signUp() }
        }
        .disabled(!isFormValid)
    }

    private func confirmationCard(email: String) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 56))
                .foregroundStyle(Theme.Colors.accent)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Check your inbox")
                    .font(.title2.weight(.semibold))
                Text("We sent a confirmation link to \(email). Tap it to finish signing up, then come back and sign in.")
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            PrimaryButton(title: "Back to sign in") {
                dismiss()
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    private var isFormValid: Bool {
        !email.isEmpty && password.count >= 6
    }

    private func signUp() async {
        isWorking = true
        defer { isWorking = false }
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespaces)
        let result = await services.auth.signUp(
            email: email,
            password: password,
            displayName: trimmedDisplayName.isEmpty ? nil : trimmedDisplayName
        )
        switch result {
        case .signedIn, .none:
            // .signedIn flips the auth state, RootView swaps to MainTabView.
            // .none means an error was set; lastError is rendered above.
            break
        case .needsEmailConfirmation(let pendingEmail):
            awaitingConfirmation = pendingEmail
        }
    }
}
