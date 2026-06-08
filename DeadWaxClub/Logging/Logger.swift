import Foundation
import OSLog
import Sentry

/// Thin wrapper that fans out to OSLog (visible in Console.app / Xcode) and Sentry.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.deadwaxclub.app"

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    static func breadcrumb(_ message: String, category: String = "app", level: SentryLevel = .info) {
        // Also log to OSLog so the message is visible in Xcode's console
        // during local debugging — without this, breadcrumbs only show up
        // in Sentry, which is no-op in dev when SENTRY_DSN is empty.
        logger(category).info("\(message, privacy: .public)")
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    static func debug(_ message: String, category: String = "app") {
        logger(category).debug("\(message, privacy: .public)")
    }

    static func event(_ name: String, category: String = "app", metadata: [String: CustomStringConvertible?] = [:]) {
        let details = metadata
            .sorted { $0.key < $1.key }
            .map { key, value in "\(key)=\(value?.description ?? "nil")" }
            .joined(separator: " ")
        breadcrumb(details.isEmpty ? name : "\(name) \(details)", category: category)
    }

    static func redactedURLDescription(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid-url>"
        }
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.map { item in
                guard Self.sensitiveURLParameterNames.contains(item.name.lowercased()) else {
                    return item
                }
                return URLQueryItem(name: item.name, value: "<redacted>")
            }
        }
        if let fragment = components.fragment {
            let redactedPairs = fragment.split(separator: "&").map { pair -> String in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let name = parts.first else { return String(pair) }
                guard Self.sensitiveURLParameterNames.contains(name.lowercased()) else {
                    return String(pair)
                }
                return "\(name)=<redacted>"
            }
            components.fragment = redactedPairs.joined(separator: "&")
        }
        return components.string ?? "<redacted-url>"
    }

    private static let sensitiveURLParameterNames: Set<String> = [
        "access_token",
        "code",
        "id_token",
        "refresh_token",
        "token",
    ]

    static func error(_ error: Error, category: String = "app", extra: [String: Any] = [:]) {
        logger(category).error("\(error.localizedDescription, privacy: .public)")
        SentrySDK.capture(error: error) { scope in
            scope.setContext(value: extra, key: "extra")
            scope.setTag(value: category, key: "category")
        }
    }

    static func warning(_ message: String, category: String = "app") {
        logger(category).warning("\(message, privacy: .public)")
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(.warning)
            scope.setTag(value: category, key: "category")
        }
    }
}
