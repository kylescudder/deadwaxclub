import AuthenticationServices
import Combine
import CryptoKit
import Foundation

@MainActor
final class AuthClient: ObservableObject {
    enum State: Equatable { case unknown, signedOut, signedIn(userID: UUID, email: String?) }
    @Published private(set) var state: State = .unknown
    @Published var lastError: String?
    @Published var isPasswordRecovery = false
    @Published private(set) var requiresReauthentication = false
    var beforeSessionInvalidation: (() async -> Void)?
    var afterSessionInvalidationFailure: (() async -> Void)?
    let api: APIClient
    private let sessionStore: any SessionStore
    private let defaults: UserDefaults
    private var bindingValidated = false
    private var pendingAppleNonce: String?
    private var resetToken: String?
    private var lastHandledCallback: (url: String, at: Date)?
    private static let recoveryPendingKey = "auth.recoveryPendingUntil"
    static let ownerKey = "sync.boundOwner"
    private struct User: Codable { let id: UUID; let email: String? }
    private struct SavedSession: Codable { let token: String; let user: User }
    private struct AuthResponse: Decodable { let token: String?; let user: User? }
    private struct SessionResponse: Decodable { let user: User }
    init(sessionStore: any SessionStore = KeychainSessionStore(), defaults: UserDefaults = .standard, api: APIClient = APIClient()) {
        self.api = api
        self.sessionStore = sessionStore
        self.defaults = defaults
        api.onUnauthorized = { [weak self] in self?.requiresReauthentication = true }
    }
    /// A cached owner keeps offline changes bound to their account, but cannot unlock the UI.
    var canAccessMainApp: Bool {
        currentUserID != nil && !requiresReauthentication && !isPasswordRecovery
    }

    var currentUserID: UUID? { if case let .signedIn(id, _) = state { id } else { nil } }

    func currentAccessToken() async -> String? {
        guard !requiresReauthentication, !isPasswordRecovery,
              let owner = currentUserID, owner == offlineOwner else { return nil }
        return api.token
    }

    func currentAccessToken(for owner: UUID) async -> String? {
        guard currentUserID == owner else { return nil }
        return await currentAccessToken()
    }

    func bootstrap(offlineAccount: () async throws -> (owners: Set<UUID>, hasPendingWrites: Bool)) async {
        guard case .unknown = state else { return }
        do {
            let account = try await offlineAccount()
            var owners = account.owners
            if let owner = offlineOwner { owners.insert(owner) }
            // Keychain access can be unavailable before the first device unlock.
            // Preserve its owner binding until the user can sign in again.
            let stored = (try? sessionStore.read()).flatMap {
                try? JSONDecoder().decode(SavedSession.self, from: $0)
            }
            if let stored { owners.insert(stored.user.id) }
            guard owners.count <= 1, !owners.isEmpty || !account.hasPendingWrites else {
                throw APIError(code: "owner_mismatch", message: "The original account for the offline changes could not be verified.")
            }
            if let owner = owners.first { defaults.set(owner.uuidString.lowercased(), forKey: Self.ownerKey) }
            bindingValidated = true
            if let stored {
                try adopt(stored)
            } else if let owner = owners.first {
                state = .signedIn(userID: owner, email: nil)
                requiresReauthentication = true
            } else {
                state = .signedOut
            }
        } catch {
            lastError = error.localizedDescription
            state = AuthAppConfiguration.bootstrapFailureState
        }
    }

    private var offlineOwner: UUID? {
        defaults.string(forKey: Self.ownerKey).flatMap(UUID.init(uuidString:))
    }

    func clearOfflineOwner() {
        defaults.removeObject(forKey: Self.ownerKey)
    }

    private func adopt(_ session: SavedSession) throws {
        guard bindingValidated else { throw APIError(code: "owner_mismatch", message: "Offline account data must be checked before signing in.") }
        let id = session.user.id.uuidString.lowercased()
        if let owner = defaults.string(forKey: Self.ownerKey), owner != id {
            throw APIError(code: "owner_mismatch", message: "Sign in with the original account to recover its offline changes. This account cannot access them.")
        }
        try sessionStore.write(JSONEncoder().encode(session))
        defaults.set(id, forKey: Self.ownerKey)
        api.token = session.token
        requiresReauthentication = false
        state = .signedIn(userID: session.user.id, email: session.user.email)
    }

    private func authenticate(_ path: String, values: [String: Any]) async throws {
        let data = try await api.json(path, values: values, authenticated: false)
        let result = try JSONDecoder().decode(AuthResponse.self, from: data)
        guard let token = result.token, let user = result.user else { throw APIError(code: "DX002", message: "Sign-in could not be completed.") }
        try adopt(SavedSession(token: token, user: user))
        defaults.removeObject(forKey: Self.recoveryPendingKey)
    }
    func signIn(email: String, password: String) async {
        lastError = nil
        do { try await authenticate("api/auth/sign-in/email", values: ["email": email, "password": password]) }
        catch { lastError = error.localizedDescription; Log.error(error, category: "auth.signIn") }
    }
    enum SignUpResult: Equatable { case signedIn, needsEmailConfirmation(email: String) }
    func signUp(email: String, password: String, displayName: String?) async -> SignUpResult? {
        lastError = nil
        do {
            _ = try await api.json("api/auth/sign-up/email", values: ["email": email, "password": password, "name": displayName ?? "", "callbackURL": AppSecrets.authRedirectURL.absoluteString], authenticated: false)
            return .needsEmailConfirmation(email: email)
        } catch { lastError = error.localizedDescription; return nil }
    }
    func resendSignupConfirmation(email: String) async -> Bool {
        lastError = nil
        do {
            _ = try await api.json("api/auth/send-verification-email", values: [
                "email": email, "callbackURL": AppSecrets.authRedirectURL.absoluteString
            ], authenticated: false)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult func signOut() async -> Bool {
        do {
            return try await performSessionInvalidation {
                // Revoke the stored session even during password recovery, where
                // currentAccessToken() withholds it from normal authenticated work.
                if api.token != nil, !requiresReauthentication { _ = try await api.json("api/auth/sign-out", values: [:]) }
                try sessionStore.write(nil)
                api.token = nil
                state = .signedOut
                requiresReauthentication = false
                defaults.removeObject(forKey: Self.recoveryPendingKey)
                // The owner binding is removed by PowerSyncManager only after a successful wipe.
                return true
            }
        } catch { lastError = error.localizedDescription; return false }
    }
    func deleteAccount() async throws {
        try await performSessionInvalidation {
            _ = try await api.request("api/account", method: "DELETE")
            try sessionStore.write(nil)
            api.token = nil
            state = .signedOut
        }
    }
    func sendPasswordReset(email: String) async -> Bool {
        do {
            _ = try await api.json("api/auth/request-password-reset", values: ["email": email, "redirectTo": "\(AuthAppConfiguration.callbackScheme)://auth-callback?type=recovery"], authenticated: false)
            defaults.set(Date().addingTimeInterval(3600), forKey: Self.recoveryPendingKey)
            return true
        } catch { lastError = error.localizedDescription; return false }
    }
    func updatePassword(newPassword: String) async -> Bool {
        do {
            return try await performSessionInvalidation {
                guard let resetToken else { throw APIError(code: "invalid_link", message: "Open the password reset link from your email again.") }
                _ = try await api.json("api/auth/reset-password", values: ["token": resetToken, "newPassword": newPassword], authenticated: false)
                self.resetToken = nil
                isPasswordRecovery = false
                defaults.removeObject(forKey: Self.recoveryPendingKey)
                try sessionStore.write(nil)
                api.token = nil
                requiresReauthentication = true
                // Keep cached account data and its pending queue for reauthentication.
                return true
            }
        } catch { lastError = error.localizedDescription; return false }
    }
    func cancelPasswordRecovery() {
        resetToken = nil
        isPasswordRecovery = false
        defaults.removeObject(forKey: Self.recoveryPendingKey)
    }

    func performSessionInvalidation<T>(_ operation: () async throws -> T) async rethrows -> T {
        await beforeSessionInvalidation?()
        do { return try await operation() }
        catch {
            await afterSessionInvalidationFailure?()
            throw error
        }
    }

    func handle(callbackURL url: URL) async {
        guard url.scheme == AuthAppConfiguration.callbackScheme, url.host == "auth-callback" else { return }
        let now = Date()
        if let last = lastHandledCallback, last.url == url.absoluteString, now.timeIntervalSince(last.at) < 5 { return }
        lastHandledCallback = (url.absoluteString, now)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value: (String) -> String? = { key in items.first { $0.name == key }?.value }
        let pending = (defaults.object(forKey: Self.recoveryPendingKey) as? Date).map { $0 > now } ?? false
        if let token = value("token"), value("type") == "recovery" || pending {
            resetToken = token
            isPasswordRecovery = true
        } else if value("error") != nil { lastError = "This link is invalid or has expired. Request a new link." }
    }
    func signInWithGoogle() async {
        lastError = nil
        do {
            guard AppSecrets.apiConfigurationError == nil else { throw APIError(code: "configuration", message: "Auth isn't configured for this build. Please install the latest build.") }
            let verifier = AppleNonce.random(length: 64)
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let url = AppSecrets.apiURL.appendingPathComponent("api/native/google").appending(queryItems: [URLQueryItem(name: "challenge", value: challenge)])
            let callback = try await GoogleSignIn.start(authURL: url, callbackScheme: AuthAppConfiguration.callbackScheme)
            guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else { throw URLError(.badServerResponse) }
            let data = try await api.json("api/native/exchange", values: ["code": code, "verifier": verifier], authenticated: false)
            struct Exchange: Decodable { let token: String }
            let token = try JSONDecoder().decode(Exchange.self, from: data).token
            let candidate = APIClient()
            candidate.token = token
            let user = try JSONDecoder().decode(SessionResponse.self, from: await candidate.request("api/auth/get-session")).user
            try adopt(SavedSession(token: token, user: user))
        } catch { handleSocialSignInError(error, category: "auth.google") }
    }
    func beginAppleSignIn(request: ASAuthorizationAppleIDRequest) {
        lastError = nil
        let nonce = AppleNonce.random()
        pendingAppleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = AppleNonce.sha256(nonce)
    }
    func completeAppleSignIn(result: Result<ASAuthorization, Error>) async {
        lastError = nil
        defer { pendingAppleNonce = nil }
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8), let nonce = pendingAppleNonce else { return }
            try await authenticate("api/auth/sign-in/social", values: ["provider": "apple", "idToken": ["token": token, "nonce": nonce]])
            if let name = credential.fullName?.givenName, !name.isEmpty {
                _ = try? await api.json(AuthAppConfiguration.initialDisplayNamePath, values: ["name": name])
            }
        } catch { handleSocialSignInError(error, category: "auth.apple") }
    }

    /// Dismissing a provider sheet is a choice, not a failed sign-in. Compare
    /// both domain and code: Apple's authorization and web-session codes overlap.
    func handleSocialSignInError(_ error: Error, category: String) {
        let nativeError = error as NSError
        if (nativeError.domain == ASAuthorizationError.errorDomain && nativeError.code == ASAuthorizationError.canceled.rawValue)
            || (nativeError.domain == ASWebAuthenticationSessionError.errorDomain && nativeError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue) {
            lastError = nil
            return
        }
        lastError = error.localizedDescription
        Log.error(error, category: category)
    }
}
