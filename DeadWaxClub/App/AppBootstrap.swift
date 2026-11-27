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
enum Analytics {
    static func identify(userID: String) {
        guard PostHogSDK.shared.getDistinctId() != userID else { return }
        PostHogSDK.shared.identify(userID)
    }

    /// Starts a new anonymous identity after sign-out. Signed-out launches
    /// keep their anonymous ID.
    static func reset() {
        let posthog = PostHogSDK.shared
        guard posthog.getDistinctId() != posthog.getAnonymousId() else { return }
        posthog.reset()
    }
}
