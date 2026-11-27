import Foundation
import PostHog

enum AppBootstrap {
    /// Starts PostHog for product analytics, error tracking and crash
    /// reporting. An empty `POSTHOG_PROJECT_TOKEN` leaves it off, and every
    /// PostHog call is then a no-op.
    static func configureAnalytics() {
        guard !AppSecrets.postHogProjectToken.isEmpty else { return }
        let config = PostHogConfig(
            projectToken: AppSecrets.postHogProjectToken,
            host: AppSecrets.postHogHost?.absoluteString ?? PostHogConfig.defaultHost
        )
        config.captureApplicationLifecycleEvents = true
        // SwiftUI screens all report as hosting controllers, so screen views
        // and element autocapture only add noise.
        config.captureScreenViews = false
        config.captureElementInteractions = false
        config.sessionReplay = false
        config.surveys = false
        config.errorTrackingConfig.autoCapture = true
        PostHogSDK.shared.setup(config)
    }
}

/// Links PostHog events to the signed-in account by its user ID only; no
/// email or profile fields are sent.
@MainActor
enum Analytics {
    enum Action: Equatable {
        case none
        case identify(userID: String)
        case reset
    }

    private static var lastState: AuthClient.State?

    /// Call with every auth state `AppServices` applies.
    static func authStateChanged(_ state: AuthClient.State) {
        let action = action(from: lastState, to: state)
        lastState = state
        let posthog = PostHogSDK.shared
        switch action {
        case .none:
            break
        case let .identify(userID):
            let current = posthog.getDistinctId()
            guard current != userID else { return }
            // Another account was identified: never merge the two people.
            if current != posthog.getAnonymousId() { posthog.reset() }
            posthog.identify(userID)
        case .reset:
            guard posthog.getDistinctId() != posthog.getAnonymousId() else { return }
            posthog.reset()
        }
    }

    /// Identify any signed-in session. Reset only when a session this launch
    /// saw signed in ends: `.unknown` while auth bootstraps, and a launch that
    /// starts signed out, keep the stored identity.
    static func action(from previous: AuthClient.State?, to state: AuthClient.State) -> Action {
        switch state {
        case let .signedIn(userID, _):
            return .identify(userID: userID.uuidString.lowercased())
        case .signedOut:
            if case .signedIn = previous { return .reset }
            return .none
        case .unknown:
            return .none
        }
    }
}
