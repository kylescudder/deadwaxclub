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

    let supabase: SupabaseClient

    private var stateTask: Task<Void, Never>?

    init() {
        self.supabase = SupabaseClient(
            supabaseURL: AppSecrets.supabaseURL,
            supabaseKey: AppSecrets.supabaseAnonKey
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
            for await (_, session) in supabase.auth.authStateChanges {
                self.apply(session: session)
            }
        }
    }

    private func apply(session: Session?) {
        if let session {
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

    func signUp(email: String, password: String, displayName: String?) async {
        lastError = nil
        do {
            _ = try await supabase.auth.signUp(email: email, password: password)
            if let displayName, !displayName.isEmpty,
               let userID = currentUserID?.uuidString {
                _ = try? await supabase
                    .from("profiles")
                    .update(["display_name": displayName])
                    .eq("id", value: userID)
                    .execute()
            }
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth")
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
                if let userID = currentUserID?.uuidString,
                   let components = credential.fullName,
                   let formatted = PersonNameComponentsFormatter().string(for: components),
                   !formatted.isEmpty {
                    _ = try? await supabase
                        .from("profiles")
                        .update(["display_name": formatted])
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
                redirectTo: AppSecrets.authRedirectURL,
                scopes: "openid email profile"
            )
            let callback = try await GoogleSignIn.start(authURL: url, callbackScheme: "deadwaxclub")
            try await supabase.auth.session(from: callback)
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.google")
        }
    }

    /// Handle a callback URL when iOS reopens the app on the deadwaxclub:// scheme
    /// (e.g. for magic links or OAuth completion routed back to the app).
    func handle(callbackURL url: URL) async {
        do {
            try await supabase.auth.session(from: url)
        } catch {
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
