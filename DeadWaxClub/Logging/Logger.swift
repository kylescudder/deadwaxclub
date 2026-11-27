import Foundation
import OSLog
import PostHog

/// Thin wrapper that fans out to OSLog (visible in Console.app / Xcode) and
/// PostHog error tracking. Breadcrumbs stay on the device: the most recent
/// ones ride along with each captured error or warning.
enum Log {
    enum Level: String, Sendable {
        case debug, info, warning, error
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "app"

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    static func breadcrumb(_ message: String, category: String = "app", level: Level = .info) {
        logger(category).info("\(message, privacy: .public)")
        Breadcrumbs.shared.append(message: message, category: category, level: level)
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
        var properties = reportProperties(category: category)
        if !extra.isEmpty {
            properties["extra"] = extra
        }
        PostHogSDK.shared.captureException(error, properties: properties)
    }

    static func warning(_ message: String, category: String = "app") {
        logger(category).warning("\(message, privacy: .public)")
        var properties = reportProperties(category: category)
        properties["$exception_level"] = Level.warning.rawValue
        let warning = NSError(domain: "\(subsystem).warning", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
        PostHogSDK.shared.captureException(warning, properties: properties)
    }

    private static func reportProperties(category: String) -> [String: Any] {
        ["category": category, "breadcrumbs": Breadcrumbs.shared.snapshot()]
    }
}

/// The last few breadcrumbs, oldest first, attached to error reports.
final class Breadcrumbs: Sendable {
    static let shared = Breadcrumbs()

    private let limit: Int
    private let entries = OSAllocatedUnfairLock(initialState: [[String: String]]())

    init(limit: Int = 50) {
        self.limit = limit
    }

    func append(message: String, category: String, level: Log.Level) {
        let entry = [
            "timestamp": Date().formatted(.iso8601),
            "category": category,
            "level": level.rawValue,
            "message": message,
        ]
        entries.withLock { entries in
            entries.append(entry)
            if entries.count > limit {
                entries.removeFirst(entries.count - limit)
            }
        }
    }

    func snapshot() -> [[String: String]] {
        entries.withLock { $0 }
    }
}
