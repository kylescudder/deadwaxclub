import AuthenticationServices
import Combine
import Foundation
import Supabase

@MainActor
final class AuthClient: ObservableObject {
    enum State: Equatable {
        case unknown
        case signedOut
        case signedIn(userID: UUID, email: String?)
    }

    @Published private(set) var state: State = .unknown
    @Published var lastError: String?
    /// Set to `true` when Supabase emits a `.passwordRecovery` auth event —
    /// i.e. the user has just opened a recovery link from their email and the
    /// client is holding a recovery session. RootView watches this and
    /// presents the "set a new password" sheet on top of whatever's on screen.
    @Published var isPasswordRecovery: Bool = false

    let supabase: SupabaseClient

    private var stateTask: Task<Void, Never>?

    init() {
        self.supabase = SupabaseClient(
            supabaseURL: AppSecrets.supabaseURL,
            supabaseKey: AppSecrets.supabaseAnonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }

    deinit { stateTask?.cancel() }

    func bootstrap() async {
        // Read current session up front so the UI doesn't hang on `.unknown`.
        do {
            let session = try await supabase.auth.session
            apply(session: session)
        } catch {
            apply(session: nil)
        }

        // Then keep listening for future changes.
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in supabase.auth.authStateChanges {
                if event == .passwordRecovery {
                    self.isPasswordRecovery = true
                }
                self.apply(session: session)
            }
        }
    }

    private func apply(session: Session?) {
        if let session, !session.isExpired {
            state = .signedIn(userID: session.user.id, email: session.user.email)
            Log.breadcrumb("session active", category: "auth")
        } else {
            state = .signedOut
            Log.breadcrumb("signed out", category: "auth")
        }
    }

    var currentUserID: UUID? {
        if case let .signedIn(id, _) = state { return id }
        return nil
    }

    /// Used by PowerSync to fetch a fresh JWT for sync.
    func currentAccessToken() async -> String? {
        do {
            return try await supabase.auth.session.accessToken
        } catch {
            return nil
        }
    }

    // MARK: - Email / password

    enum SignUpResult: Equatable {
        /// Supabase has email-confirmation off; we got a session and the user is signed in.
        case signedIn
        /// Confirmation email sent; we'll only get a session once the user clicks the link.
        case needsEmailConfirmation(email: String)
    }

    func signUp(email: String, password: String, displayName: String?) async -> SignUpResult? {
        lastError = nil
        do {
            // Hand the display name through `raw_user_meta_data` so the
            // `handle_new_user` trigger picks it up at insert time — works
            // regardless of whether email confirmation is on.
            let metadata: [String: AnyJSON]?
            if let displayName, !displayName.isEmpty {
                metadata = ["display_name": .string(displayName)]
            } else {
                metadata = nil
            }
            // `redirectTo` is where Supabase sends the user after the email
            // confirmation link is verified — has to land on the app so
            // `session(from:)` can extract the tokens and sign them in.
            let response = try await supabase.auth.signUp(
                email: email,
                password: password,
                data: metadata,
                redirectTo: AppSecrets.authRedirectURL
            )
            return response.session != nil
                ? .signedIn
                : .needsEmailConfirmation(email: email)
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth")
            return nil
        }
    }

    func signIn(email: String, password: String) async {
        lastError = nil
        do {
            _ = try await supabase.auth.signIn(email: email, password: password)
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth")
        }
    }

    // MARK: - Password reset

    /// Triggers Supabase to send a password-recovery email. The link in the
    /// email opens the app on `authRedirectURL`; `handle(callbackURL:)` then
    /// establishes a recovery session and the auth-state listener flips
    /// `isPasswordRecovery`, prompting RootView to show the reset sheet.
    func sendPasswordReset(email: String) async -> Bool {
        lastError = nil
        do {
            try await supabase.auth.resetPasswordForEmail(
                email,
                redirectTo: AppSecrets.authRedirectURL
            )
            return true
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.passwordReset")
            return false
        }
    }

    /// Sets a new password against the active recovery session. On success the
    /// recovery flag clears and Supabase upgrades the session to a normal
    /// signed-in one (the user stays logged in).
    func updatePassword(newPassword: String) async -> Bool {
        lastError = nil
        do {
            _ = try await supabase.auth.update(user: UserAttributes(password: newPassword))
            isPasswordRecovery = false
            return true
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.updatePassword")
            return false
        }
    }

    // MARK: - Apple

    private var pendingAppleNonce: String?

    /// Configures the request — required so we can supply the nonce that
    /// supabase-swift will validate against the returned identity token.
    func beginAppleSignIn(request: ASAuthorizationAppleIDRequest) {
        let nonce = AppleNonce.random()
        pendingAppleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = AppleNonce.sha256(nonce)
    }

    func completeAppleSignIn(result: Result<ASAuthorization, Error>) async {
        defer { pendingAppleNonce = nil }
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            lastError = error.localizedDescription
            Log.error(error, category: "auth.apple")
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8),
                  let nonce = pendingAppleNonce else {
                lastError = "Apple did not return an identity token."
                return
            }
            do {
                _ = try await supabase.auth.signInWithIdToken(
                    credentials: .init(provider: .apple, idToken: token, nonce: nonce)
                )
                // Apple only returns the name on the very first sign-in.
                // We prefer the given name alone (matches the in-app casual
                // handle convention; user can edit from Settings).
                if let userID = currentUserID?.lowerUUID,
                   let firstName = credential.fullName?.givenName?
                       .trimmingCharacters(in: .whitespaces),
                   !firstName.isEmpty {
                    _ = try? await supabase
                        .from("profiles")
                        .update(["display_name": firstName])
                        .eq("id", value: userID)
                        .execute()
                }
            } catch {
                lastError = error.localizedDescription
                Log.error(error, category: "auth.apple")
            }
        }
    }

    // MARK: - Google OAuth

    func signInWithGoogle() async {
        lastError = nil
        do {
            // Build the Supabase OAuth URL, then drive the web flow ourselves
            // via ASWebAuthenticationSession so we get full control of the
            // callback URL.
            let url = try supabase.auth.getOAuthSignInURL(
                provider: .google,
                scopes: "openid email profile",
                redirectTo: AppSecrets.authRedirectURL
            )
            let callback = try await GoogleSignIn.start(authURL: url, callbackScheme: "deadwaxclub")
            try await supabase.auth.session(from: callback)
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.google")
        }
    }

    /// Handle a callback URL when iOS reopens the app on the deadwaxclub:// scheme
    /// (e.g. for magic links, email confirmation, OAuth completion).
    func handle(callbackURL url: URL) async {
        Log.breadcrumb("auth callback url: \(url.absoluteString)", category: "auth.callback")
        do {
            try await supabase.auth.session(from: url)
            Log.breadcrumb("auth callback session established", category: "auth.callback")
        } catch {
            // Common failure: URL is missing tokens because an email client
            // (Gmail web, Outlook) wrapped the link in a tracker that stripped
            // them. The PKCE `?code=...` form survives this; the implicit
            // `#access_token=...` form doesn't.
            lastError = "Couldn't finish signing in from this link. Try signing in directly with your email and password."
            Log.error(error, category: "auth.callback")
        }
    }

    func signOut() async {
        do {
            try await supabase.auth.signOut()
        } catch {
            Log.error(error, category: "auth")
        }
    }

    /// Calls the `delete_my_account` Postgres function which removes the
    /// auth.users row; cascading FKs handle the rest of the user's data.
    /// Locally any cached cover art is purged after the RPC succeeds.
    func deleteAccount() async throws {
        try await supabase.rpc("delete_my_account").execute()
        try await supabase.auth.signOut()
    }
}
