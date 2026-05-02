import Foundation
import Supabase
import Combine

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
            let callback = try await GoogleSignIn.start(authURL: url, callbackScheme: "trackd")
            try await supabase.auth.session(from: callback)
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "auth.google")
        }
    }

    /// Handle a callback URL when iOS reopens the app on the trackd:// scheme
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
}
