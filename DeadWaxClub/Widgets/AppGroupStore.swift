import Foundation

/// App-group storage shared by the app and its widget extension. This file is
/// identical in every app and compiled into both targets; the group ID is
/// `WidgetSnapshotStore.appGroupID`, and the snapshot types and keys live in
/// the app's `WidgetSnapshotStore.swift`.
enum AppGroupStore {
    static var defaults: UserDefaults {
        UserDefaults(suiteName: WidgetSnapshotStore.appGroupID) ?? .standard
    }

    /// The shared container, or a temporary directory when the app group is
    /// unavailable (for example in unsigned builds).
    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroupID)
            ?? FileManager.default.temporaryDirectory
    }

    static func load<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    static func remove(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}
