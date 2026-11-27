import Foundation

/// Build values from `Config/Secrets.xcconfig`, surfaced through `Info.plist`.
///
/// A missing, unresolved or placeholder origin becomes a configuration error
/// instead of a crash: simulator and pull-request builds deliberately use the
/// example xcconfig. An empty `POSTHOG_PROJECT_TOKEN` disables PostHog.
enum AppSecrets {
    static let apiConfigurationError = configurationError(for: "API_URL")
    static let apiURL = origin(from: string(for: "API_URL")) ?? URL(string: "https://configuration.invalid")!

    static let powerSyncConfigurationError = configurationError(for: "POWERSYNC_URL")
    static let powerSyncURL = origin(from: string(for: "POWERSYNC_URL"))

    static let postHogProjectToken = string(for: "POSTHOG_PROJECT_TOKEN")
    /// PostHog ingestion origin; unset falls back to the SDK default.
    static let postHogHost = origin(from: string(for: "POSTHOG_HOST"))

    /// `<scheme>://auth-callback`, where the scheme is the one registered by the
    /// `*.auth` URL type in `Info.plist` (generated from `project.yml`).
    static let authRedirectURL = URL(string: "\(authCallbackScheme(in: Bundle.main.infoDictionary) ?? "invalid")://auth-callback")!

    /// An `https` origin, or `http` on a loopback host for local development.
    /// Unresolved `$(…)` values, `.invalid` hosts and the PowerSync dashboard
    /// placeholder are treated as unset.
    static func origin(from raw: String) -> URL? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains("$("),
              let parts = URLComponents(string: raw),
              let host = parts.host?.lowercased(), !host.isEmpty,
              !host.hasSuffix(".invalid"), !placeholderHosts.contains(host),
              parts.scheme == "https" || (parts.scheme == "http" && localHosts.contains(host)),
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { return nil }
        var origin = parts
        origin.path = ""
        return origin.url
    }

    static func authCallbackScheme(in info: [String: Any]?) -> String? {
        let types = info?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let auth = types.first { ($0["CFBundleURLName"] as? String)?.hasSuffix(".auth") == true }
        return (auth?["CFBundleURLSchemes"] as? [String])?.first
    }

    private static let placeholderHosts: Set<String> = ["your-instance.powersync.journeyapps.com"]
    private static let localHosts: Set<String> = ["localhost", "127.0.0.1"]

    private static func string(for key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func configurationError(for key: String) -> String? {
        origin(from: string(for: key)) == nil ? "\(key) is not configured for this build." : nil
    }
}
