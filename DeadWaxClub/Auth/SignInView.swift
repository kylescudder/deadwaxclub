import SwiftUI

/// The shared sign-in screen: email and password, Apple, Google, password
/// reset, and the offline-account recovery choice. This file is identical in
/// every app; branding comes from `AuthAppConfiguration`.
struct SignInView: View {
    @EnvironmentObject private var services: AppServices
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var showSignUp = false
    @State private var showForgotPassword = false
    @State private var showDiscardConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                VStack(spacing: Theme.Spacing.sm) {
                    Image(AuthAppConfiguration.signInLogo.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: AuthAppConfiguration.signInLogo.size, height: AuthAppConfiguration.signInLogo.size)
                        .clipShape(RoundedRectangle(cornerRadius: AuthAppConfiguration.signInLogo.cornerRadius))
                    Text(AuthAppConfiguration.signInTitle)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(AuthAppConfiguration.signInTagline)
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, Theme.Spacing.xxl)

                if services.auth.requiresReauthentication {
                    Text("Please sign in again to pick up where you left off.")
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: Theme.Spacing.md) {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding()
                        .background(Theme.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .padding()
                        .background(Theme.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                    HStack {
                        Spacer()
                        Button("Forgot password?") { showForgotPassword = true }
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.accent)
                    }
                }

                if let error = services.auth.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: Theme.Spacing.md) {
                    PrimaryButton(title: "Sign in", isLoading: isWorking) {
                        Task { await signIn() }
                    }
                    .disabled(!isFormValid || isWorking)

                    HStack {
                        Rectangle().fill(Theme.Colors.separator).frame(height: 1)
                        Text("or").font(.footnote).foregroundStyle(Theme.Colors.textTertiary)
                        Rectangle().fill(Theme.Colors.separator).frame(height: 1)
                    }

                    AppleSignInButton()
                        .frame(height: 50)
                        .disabled(isWorking)

                    SecondaryButton(
                        title: "Continue with Google",
                        assetImage: "GoogleLogo",
                        iconTextSpacing: 12,
                        titleFont: .custom("Roboto-Medium", size: 17, relativeTo: .body)
                    ) {
                        Task { await googleSignIn() }
                    }
                    .disabled(isWorking)
                }

                if services.auth.requiresReauthentication {
                    Button("Use a different account") {
                        showDiscardConfirmation = true
                    }
                    .font(.callout)
                } else {
                    Button("Create an account") { showSignUp = true }
                        .font(.callout)
                        .padding(.top, Theme.Spacing.sm)
                }
            }
            .disabled(isWorking)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Theme.Colors.background)
        .scrollDismissesKeyboard(.interactively)
        .alert("Use a different account?", isPresented: $showDiscardConfirmation) {
            Button("Switch account", role: .destructive) {
                Task { await discardLocalAccount() }
            }
            Button("Stay here", role: .cancel) {}
        } message: {
            Text("Any changes on this phone that haven’t been saved to your account will be lost. Everything already saved to your account will still be there when you sign back in.")
        }
        .navigationDestination(isPresented: $showSignUp) { SignUpView() }
        .sheet(isPresented: $showForgotPassword) {
            ForgotPasswordSheet(initialEmail: email)
                .presentationDetents([.medium, .large])
        }
    }

    private var isFormValid: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && password.count >= 6
    }

    private func discardLocalAccount() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        if await services.auth.signOut() {
            await services.sync.wipe()
            AuthAppConfiguration.didDiscardLocalAccount(services)
            services.auth.lastError = nil
            email = ""
            password = ""
        }
    }

    private func signIn() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await services.auth.signIn(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
    }

    private func googleSignIn() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await services.auth.signInWithGoogle()
    }
}

/// The logo at the top of the sign-in screen. A zero corner radius leaves
/// the image unclipped.
struct SignInLogo: Sendable {
    let imageName: String
    let size: CGFloat
    let cornerRadius: CGFloat
}
