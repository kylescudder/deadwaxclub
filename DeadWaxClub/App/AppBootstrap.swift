import Foundation
import Sentry

enum AppBootstrap {
    static func configureSentry() {
        guard !AppSecrets.sentryDSN.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = AppSecrets.sentryDSN
            options.debug = false
            options.tracesSampleRate = 0.2
            options.attachStacktrace = true
            options.enableAutoPerformanceTracing = true
            options.enableNetworkBreadcrumbs = true
            options.releaseName = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        }
    }
}
