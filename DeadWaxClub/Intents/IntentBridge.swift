import Foundation

/// Static bridge from AppIntents (which run in their own extension-like
/// context with no `@EnvironmentObject`) into the live AppServices instance.
/// `DeadWaxClubApp` registers itself on launch so intents can read/write through
/// the same PowerSync database the UI uses.
enum IntentBridge {
    /// Set by `DeadWaxClubApp` shortly after launch.
    @MainActor static weak var services: AppServices?

    @MainActor
    static func searchRecords(query: String) async throws -> [VinylRecordEntity] {
        guard let services else { return [] }
        let q = "%\(query.lowercased())%"
        let rows = try await services.sync.database.getAll(
            sql: """
            select * from records
            where deleted_at is null
              and status = 'owned'
              and (lower(title) like ? or lower(artist) like ? or lower(colourway) like ?)
            order by updated_at desc
            limit 25
            """,
            parameters: [q, q, q],
            mapper: { VinylRecord.from(cursor: $0) }
        )
        return rows.compactMap { $0 }.map(VinylRecordEntity.init(record:))
    }

    @MainActor
    static func recordsByID(_ ids: [String]) async throws -> [VinylRecordEntity] {
        guard let services, !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let rows = try await services.sync.database.getAll(
            sql: "select * from records where id in (\(placeholders)) and deleted_at is null",
            parameters: ids,
            mapper: { VinylRecord.from(cursor: $0) }
        )
        return rows.compactMap { $0 }.map(VinylRecordEntity.init(record:))
    }

    @MainActor
    static func recentRecords(limit: Int) async throws -> [VinylRecordEntity] {
        guard let services else { return [] }
        let rows = try await services.sync.database.getAll(
            sql: """
            select * from records
            where deleted_at is null
              and status = 'owned'
            order by updated_at desc limit ?
            """,
            parameters: [limit],
            mapper: { VinylRecord.from(cursor: $0) }
        )
        return rows.compactMap { $0 }.map(VinylRecordEntity.init(record:))
    }

    @MainActor
    static func logPrice(recordID: String, priceMajor: Double, currency: String, shop: String?) async throws {
        guard let services, let ownerID = services.auth.currentUserID?.lowerUUID else {
            throw NSError(domain: "deadwaxclub.intents", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Sign in to Deadwax Club to log prices."
            ])
        }
        // PriceEntry inherits the parent record's Collection.
        let collectionID: String? = try await services.sync.database.getOptional(
            sql: "select collection_id from records where id = ? limit 1",
            parameters: [recordID],
            mapper: { try $0.getString(name: "collection_id") }
        )
        guard let collectionID else {
            throw NSError(domain: "deadwaxclub.intents", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Record not found."
            ])
        }
        let entry = PriceEntry(
            id: UUID().lowerUUID,
            recordID: recordID,
            ownerID: ownerID,
            collectionID: collectionID,
            priceCents: Int((priceMajor * 100).rounded()),
            currency: currency,
            shopName: shop,
            scannedAt: Date(),
            createdAt: Date()
        )
        await services.prices.add(entry)
    }
}
