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
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

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
