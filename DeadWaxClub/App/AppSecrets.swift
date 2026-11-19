import Foundation

enum AppSecrets {
    private static func httpsOrigin(_ key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let parts = URLComponents(string: value),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.fragment == nil, parts.path.isEmpty else { return nil }
        return parts.url
    }

    private static let configuredAPI = httpsOrigin("API_URL")
    static let apiURL = configuredAPI ?? URL(string: "https://invalid.invalid")!
    static let apiConfigurationError = configuredAPI == nil ? "The Deadwax API is not configured." : nil
    static let powerSyncURL = httpsOrigin("POWERSYNC_URL")

    static let sentryDSN = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String ?? ""
    static let authRedirectURL = URL(string: "deadwaxclub://auth-callback")!
}
