import Foundation

/// Build-time secrets read from Info.plist (which pulls from Config/Secrets.xcconfig).
/// See README for setup. Empty strings are treated as "not configured" and the
/// dependent feature is disabled gracefully.
enum AppSecrets {
    static let supabaseURL: URL = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              let url = URL(string: raw), !raw.isEmpty else {
            assertionFailure("SUPABASE_URL is not set in Secrets.xcconfig")
            return URL(string: "https://placeholder.supabase.co")!
        }
        return url
    }()

    static let supabaseAnonKey: String = {
        Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
    }()

    static let powerSyncURL: URL = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "POWERSYNC_URL") as? String ?? ""
        return URL(string: raw) ?? URL(string: "https://placeholder.powersync.journeyapps.com")!
    }()

    static let sentryDSN: String = {
        Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String ?? ""
    }()

    static let authRedirectURL: URL = URL(string: "deadwaxclub://auth-callback")!
}
