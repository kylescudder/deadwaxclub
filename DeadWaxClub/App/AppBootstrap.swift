import Foundation
import PostHog

enum AppBootstrap {
    /// Starts PostHog for product analytics, error tracking and crash
    /// reporting. An empty `POSTHOG_PROJECT_TOKEN` leaves it off, and every
    /// PostHog call is then a no-op.
    ///
    /// The apps share one PostHog project. Every event, error and crash report
    /// carries `app` (see `AnalyticsApp`), and identified users are namespaced
    /// by bundle ID, so filter by `app` to see one app.
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
        // beforeSend runs for every event, and unlike a registered super
        // property it survives `reset()` on sign-out.
        let app = AnalyticsApp.current
        config.setBeforeSend { event in
            event.properties = app.tagging(event.properties)
            return event
        }
        PostHogSDK.shared.setup(config)
    }
}

/// The app's identity inside the shared PostHog project.
struct AnalyticsApp: Equatable, Sendable {
    static let propertyKey = "app"
    static let current = AnalyticsApp(info: Bundle.main.infoDictionary, bundleIdentifier: Bundle.main.bundleIdentifier)

    /// Readable filter value: the app target name (`CFBundleExecutable`).
    let name: String
    /// Bundle ID: unique per app, so it namespaces distinct IDs.
    let namespace: String

    init(name: String, namespace: String) {
        self.name = name
        self.namespace = namespace
    }

    init(info: [String: Any]?, bundleIdentifier: String?) {
        let namespace = bundleIdentifier ?? "app"
        let name = (info?["CFBundleExecutable"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? namespace
        self.init(name: name, namespace: namespace)
    }

    /// The PostHog distinct ID for an account. Each app has its own backend
    /// and users table, so a bare user ID must never identify a person
    /// across apps.
    func distinctID(for userID: UUID) -> String {
        "\(namespace):\(userID.uuidString.lowercased())"
    }

    func tagging(_ properties: [String: Any]) -> [String: Any] {
        var properties = properties
        properties[Self.propertyKey] = name
        return properties
    }
}

/// Links PostHog events to the signed-in account by its namespaced user ID
/// only; no email or profile fields are sent.
@MainActor
enum Analytics {
    enum Action: Equatable {
        case none
        case identify(distinctID: String)
        case reset
    }

    private static var lastState: AuthClient.State?

    /// Call with every auth state `AppServices` applies.
    static func authStateChanged(_ state: AuthClient.State) {
        let app = AnalyticsApp.current
        let action = action(from: lastState, to: state, in: app)
        lastState = state
        let posthog = PostHogSDK.shared
        switch action {
        case .none:
            break
        case let .identify(distinctID):
            let current = posthog.getDistinctId()
            guard current != distinctID else { return }
            // Another account was identified: never merge the two people.
            if current != posthog.getAnonymousId() { posthog.reset() }
            posthog.identify(distinctID, userProperties: [AnalyticsApp.propertyKey: app.name])
        case .reset:
            guard posthog.getDistinctId() != posthog.getAnonymousId() else { return }
            posthog.reset()
        }
    }

    /// Identify any signed-in session. Reset only when a session this launch
    /// saw signed in ends: `.unknown` while auth bootstraps, and a launch that
    /// starts signed out, keep the stored identity.
    static func action(from previous: AuthClient.State?, to state: AuthClient.State, in app: AnalyticsApp) -> Action {
        switch state {
        case let .signedIn(userID, _):
            return .identify(distinctID: app.distinctID(for: userID))
        case .signedOut:
            if case .signedIn = previous { return .reset }
            return .none
        case .unknown:
            return .none
        }
    }
}
