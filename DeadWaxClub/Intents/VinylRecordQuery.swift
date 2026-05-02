import AppIntents
import Foundation

/// Lets Shortcuts and Siri search the user's records.
struct VinylRecordQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [VinylRecordEntity] {
        try await IntentBridge.searchRecords(query: string)
    }

    func entities(for identifiers: [String]) async throws -> [VinylRecordEntity] {
        try await IntentBridge.recordsByID(identifiers)
    }

    func suggestedEntities() async throws -> [VinylRecordEntity] {
        try await IntentBridge.recentRecords(limit: 10)
    }
}
