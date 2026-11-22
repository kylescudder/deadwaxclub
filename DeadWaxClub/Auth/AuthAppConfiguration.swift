import Foundation

@MainActor
enum AuthAppConfiguration {
    static let callbackScheme = "deadwaxclub"
    static let keychainService = "com.deadwaxclub.app.auth"
    static let initialDisplayNamePath = "api/library/set_initial_display_name"
    static let bootstrapFailureState: AuthClient.State = .unknown

    // Shared sign-in views
    static let signInLogo = SignInLogo(imageName: "AppLogo", size: 96, cornerRadius: 0)
    static let signInTitle = "Deadwax Club"
    static let signInTagline = "Track the vinyl you own and the vinyl you want."
    /// Leaving the reset-password sheet keeps the session and local data.
    static let passwordRecoveryExit = PasswordRecoveryExit.cancelRecovery

    /// Onboarding is re-evaluated for whichever account signs in next.
    static func didDiscardLocalAccount(_ services: AppServices) {
        services.onboarding.resetForSignOut()
    }
}
