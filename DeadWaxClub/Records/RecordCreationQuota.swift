import Foundation

enum RecordCreationError: Error, Equatable, Sendable {
    case quotaSnapshotUnavailable
    case freeLimitReached
    case missingCreator
}

enum RecordQuotaSnapshot {
    static func requireInitializedCount(_ count: Int?) throws -> Int {
        guard let count else { throw RecordCreationError.quotaSnapshotUnavailable }
        return count
    }
}
