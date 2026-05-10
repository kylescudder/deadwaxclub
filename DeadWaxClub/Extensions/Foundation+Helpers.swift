import Foundation

extension UUID {
    /// SQLite is case-sensitive while Postgres normalises UUIDs to lowercase.
    /// Mixing cases produces "row exists in Postgres but not SQLite" desyncs,
    /// so every UUID written from the app must be lowercased.
    var lowerUUID: String { uuidString.lowercased() }
}

extension Date {
    var iso8601: String { ISO8601DateFormatter.iso.string(from: self) }
}
