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

    private enum AuthOperationError: LocalizedError {
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .timedOut(let operation):
                return "\(operation) timed out. Check your connection and try again."
            }
        }
    }

    private final class AuthContinuationGate<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(throwing: error)
        }
    }

    private static let authOperationTimeoutSeconds = 20

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
        Log.breadcrumb("auth bootstrap started", category: "auth")
        // Read current session up front so the UI doesn't hang on `.unknown`.
        do {
            let session = try await supabase.auth.session
            Log.event("auth bootstrap session read", category: "auth", metadata: [
                "hasSession": true,
                "isExpired": session.isExpired,
            ])
            apply(session: session)
        } catch {
            Log.event("auth bootstrap has no active session", category: "auth", metadata: ["reason": error.localizedDescription])
            apply(session: nil)
        }

        // Then keep listening for future changes.
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in supabase.auth.authStateChanges {
                Log.event("auth state changed", category: "auth", metadata: [
                    "event": String(describing: event),
                    "hasSession": session != nil,
                ])
                if event == .passwordRecovery {
                    self.isPasswordRecovery = true
                    Log.breadcrumb("password recovery auth event received", category: "auth")
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
        if case .signedIn(let id, _) = state { return id }
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

    private func withAuthTimeout<T>(
        operationName: String,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = AuthContinuationGate(continuation)
            let task = Task { @MainActor in
                do {
                    gate.resume(returning: try await operation())
                } catch {
                    gate.resume(throwing: error)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Self.authOperationTimeoutSeconds)) {
                task.cancel()
                gate.resume(throwing: AuthOperationError.timedOut(operationName))
            }
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
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        Log.event("signup started", category: "auth", metadata: ["hasDisplayName": displayName?.isEmpty == false])
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
            let client = supabase
            let response = try await withAuthTimeout(operationName: "Sign up") {
                try await client.auth.signUp(
                    email: trimmedEmail,
                    password: password,
                    data: metadata,
                    redirectTo: AppSecrets.authRedirectURL
                )
            }
            // Either branch means the user took an explicit signup action,
            // so any stashed reset-password intent is stale.
            AuthClient.clearPendingRecoveryFlag()
            let result: SignUpResult = response.session != nil
                ? .signedIn
                : .needsEmailConfirmation(email: trimmedEmail)
            Log.event("signup completed", category: "auth", metadata: [
                "createdSession": response.session != nil,
                "needsEmailConfirmation": response.session == nil,
            ])
            return result
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth")
            return nil
        }
    }

    func resendSignupConfirmation(email: String) async -> Bool {
        lastError = nil
        do {
            try await supabase.auth.resend(
                email: email,
                type: .signup,
                emailRedirectTo: AppSecrets.authRedirectURL
            )
            return true
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.resendConfirmation")
            return false
        }
    }

    func signIn(email: String, password: String) async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        Log.breadcrumb("email signin started", category: "auth")
        do {
            let client = supabase
            _ = try await withAuthTimeout(operationName: "Sign in") {
                try await client.auth.signIn(email: trimmedEmail, password: password)
            }
            AuthClient.clearPendingRecoveryFlag()
            Log.breadcrumb("email signin completed", category: "auth")
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
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        Log.breadcrumb("password reset requested", category: "auth.reset")
        do {
            let client = supabase
            try await withAuthTimeout(operationName: "Password reset") {
                try await client.auth.resetPasswordForEmail(
                    trimmedEmail,
                    redirectTo: AppSecrets.authRedirectURL
                )
            }
            // Self-hosted GoTrue's PKCE redirect can omit `type=recovery`, so
            // we record that recovery is pending for this device — the next
            // PKCE callback within an hour is treated as recovery even if the
            // URL doesn't carry the type qualifier.
            UserDefaults.standard.set(
                Date().addingTimeInterval(3600),
                forKey: AuthClient.recoveryPendingKey
            )
            Log.breadcrumb("password reset email sent", category: "auth.reset")
            return true
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.passwordReset")
            return false
        }
    }

    private static let recoveryPendingKey = "auth.recoveryPendingUntil"

    private static func consumePendingRecoveryFlag() -> Bool {
        let key = AuthClient.recoveryPendingKey
        guard let until = UserDefaults.standard.object(forKey: key) as? Date else {
            return false
        }
        UserDefaults.standard.removeObject(forKey: key)
        return until > Date()
    }

    /// Drops the pending-recovery flag without checking its value. Called from
    /// every other auth success path so the flag can only survive when nothing
    /// else has happened — otherwise a signup confirmation or magic link
    /// clicked within the 1-hour window would falsely trigger the reset sheet.
    private static func clearPendingRecoveryFlag() {
        UserDefaults.standard.removeObject(forKey: AuthClient.recoveryPendingKey)
    }

    /// Sets a new password against the active recovery session. On success we
    /// drop the recovery flag *and* sign the user out, so they have to come
    /// back through SignInView with their fresh password — letting the
    /// recovery session silently log them straight in would be both confusing
    /// (no proof they actually know the new password) and a soft security
    /// downgrade against shoulder-surfing the email link.
    func updatePassword(newPassword: String) async -> Bool {
        lastError = nil
        Log.breadcrumb("password update started", category: "auth.updatePassword")
        do {
            let client = supabase
            _ = try await withAuthTimeout(operationName: "Password update") {
                try await client.auth.update(user: UserAttributes(password: newPassword))
            }
            isPasswordRecovery = false
            try await client.auth.signOut()
            Log.breadcrumb("password updated; recovery session signed out", category: "auth.updatePassword")
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
        Log.breadcrumb("apple signin started", category: "auth.apple")
        let nonce = AppleNonce.random()
        pendingAppleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = AppleNonce.sha256(nonce)
    }

    func completeAppleSignIn(result: Result<ASAuthorization, Error>) async {
        defer { pendingAppleNonce = nil }
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled {
                Log.breadcrumb("apple signin cancelled", category: "auth.apple")
                return
            }
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
                let client = supabase
                _ = try await withAuthTimeout(operationName: "Apple sign in") {
                    try await client.auth.signInWithIdToken(
                        credentials: .init(provider: .apple, idToken: token, nonce: nonce)
                    )
                }
                AuthClient.clearPendingRecoveryFlag()
                Log.breadcrumb("apple signin completed", category: "auth.apple")
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
        Log.breadcrumb("google signin started", category: "auth.google")
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
            let client = supabase
            try await withAuthTimeout(operationName: "Google sign in") {
                try await client.auth.session(from: callback)
            }
            AuthClient.clearPendingRecoveryFlag()
            Log.breadcrumb("google signin completed", category: "auth.google")
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.google")
        }
    }

    /// Handle a callback URL when iOS reopens the app on the deadwaxclub:// scheme
    /// (e.g. for magic links, email confirmation, password recovery, OAuth
    /// completion).
    ///
    /// We dedupe rapid duplicate invocations because RootView and SignInView
    /// both used to install onOpenURL handlers — the second call would try to
    /// re-exchange a one-time recovery code that the first call had already
    /// consumed, throwing a misleading error onto lastError.
    private var lastHandledCallback: (url: String, at: Date)?

    func handle(callbackURL url: URL) async {
        let now = Date()
        if let last = lastHandledCallback,
           last.url == url.absoluteString,
           now.timeIntervalSince(last.at) < 5 {
            Log.breadcrumb("auth callback ignored (duplicate within 5s)", category: "auth.callback")
            return
        }
        lastHandledCallback = (url.absoluteString, now)

        // Two signals tell us this is a recovery callback:
        //   1. `type=recovery` in the URL (PKCE on hosted Supabase does this).
        //   2. A pending-recovery flag we stashed when sendPasswordReset
        //      succeeded (self-hosted GoTrue's PKCE redirect omits the type
        //      qualifier, so we'd otherwise treat it as a normal sign-in).
        // We compute both before consuming the flag so the OSLog line is
        // diagnosable.
        let urlSaysRecovery = AuthClient.urlContainsTypeRecovery(url)
        let flagSaysRecovery = AuthClient.consumePendingRecoveryFlag()
        let isRecovery = urlSaysRecovery || flagSaysRecovery

        Log.breadcrumb(
            "auth callback url: \(Log.redactedURLDescription(url)) recovery=\(isRecovery) (urlSays=\(urlSaysRecovery) flagSays=\(flagSaysRecovery))",
            category: "auth.callback"
        )
        // Flip the flag *before* session(from:) returns so the state change
        // and the recovery flag land in the same render pass — otherwise
        // RootView momentarily renders MainTabView underneath the sheet.
        if isRecovery {
            self.isPasswordRecovery = true
        }
        do {
            let client = supabase
            try await withAuthTimeout(operationName: "Auth callback") {
                try await client.auth.session(from: url)
            }
            Log.breadcrumb("auth callback session established", category: "auth.callback")
        } catch {
            if isRecovery {
                self.isPasswordRecovery = false
            }
            lastError = "Couldn't finish from this link: \(error.localizedDescription)"
            Log.error(error, category: "auth.callback")
        }
    }

    /// True when the URL carries `type=recovery` in either its query string
    /// (PKCE-style `?code=...&type=recovery`) or its fragment (implicit-style
    /// `#access_token=...&type=recovery&...`).
    private static func urlContainsTypeRecovery(_ url: URL) -> Bool {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        if comps.queryItems?.contains(where: { $0.name == "type" && $0.value == "recovery" }) == true {
            return true
        }
        if let fragment = comps.fragment {
            for pair in fragment.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[0] == "type", parts[1] == "recovery" {
                    return true
                }
            }
        }
        return false
    }

    func signOut() async {
        AuthClient.clearPendingRecoveryFlag()
        Log.breadcrumb("signout started", category: "auth")
        do {
            try await supabase.auth.signOut()
            Log.breadcrumb("signout completed", category: "auth")
        } catch {
            Log.error(error, category: "auth")
        }
    }

    /// Calls the `delete_my_account` Postgres function which removes the
    /// auth.users row; cascading FKs handle the rest of the user's data.
    /// Locally any cached cover art is purged after the RPC succeeds.
    func deleteAccount() async throws {
        Log.breadcrumb("account deletion started", category: "auth.deleteAccount")
        try await supabase.rpc("delete_my_account").execute()
        try await supabase.auth.signOut()
        Log.breadcrumb("account deletion completed", category: "auth.deleteAccount")
    }
}
