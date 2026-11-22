import SwiftUI
import AuthenticationServices

/// Native `SignInWithAppleButton` wrapper that runs the request through
/// AuthClient (which sets the nonce, exchanges the Apple ID token with the
/// Deadwax API, and persists display name on first authorization).
struct AppleSignInButton: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        SignInWithAppleButton(
            .continue,
            onRequest: { request in
                services.auth.beginAppleSignIn(request: request)
            },
            onCompletion: { result in
                Task { await services.auth.completeAppleSignIn(result: result) }
            }
        )
        .signInWithAppleButtonStyle(.black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}
