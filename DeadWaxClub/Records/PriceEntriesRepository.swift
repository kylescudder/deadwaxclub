import Foundation
import PowerSync

@MainActor
final class PriceEntriesRepository: ObservableObject {
    @Published private(set) var entries: [PriceEntry] = []

    private let database: PowerSyncDatabaseProtocol
    private var watchTask: Task<Void, Never>?

    init(database: PowerSyncDatabaseProtocol) {
        self.database = database
    }

    deinit { watchTask?.cancel() }

    func startWatching(recordID: String) {
        Log.event("price watch starting", category: "prices.watch", metadata: ["recordID": recordID])
        watchTask?.cancel()
        watchTask = Task { [weak self, database] in
            guard let self else { return }
            let sql = """
                select * from price_entries
                where record_id = ? and deleted_at is null
                order by scanned_at asc
            """
            do {
                let stream = try database.watch(
                    sql: sql,
                    parameters: [recordID],
                    mapper: { PriceEntry.from(cursor: $0) }
                )
                for try await rows in stream {
                    let mapped = rows.compactMap { $0 }
                    Log.event("price watch emitted", category: "prices.watch", metadata: [
                        "recordID": recordID,
                        "count": mapped.count,
                    ])
                    await MainActor.run { self.entries = mapped }
                }
            } catch {
                Log.error(error, category: "prices.watch")
            }
        }
    }

    func add(_ entry: PriceEntry) async {
        Log.event("price add started", category: "prices.add", metadata: [
            "entryID": entry.id,
            "recordID": entry.recordID,
            "collectionID": entry.collectionID,
            "currency": entry.currency,
            "hasShopName": entry.shopName?.isEmpty == false,
        ])
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: """
                insert into price_entries
                  (id, record_id, owner_id, collection_id, price_cents, currency, shop_name, scanned_at, created_at, updated_at)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                parameters: [
                    entry.id,
                    entry.recordID,
                    entry.ownerID,
                    entry.collectionID,
                    entry.priceCents,
                    entry.currency,
                    entry.shopName,
                    entry.scannedAt.iso8601,
                    entry.createdAt.iso8601,
                    now,
                ]
            )
            Log.event("price add completed", category: "prices.add", metadata: ["entryID": entry.id, "recordID": entry.recordID])
        } catch {
            Log.error(error, category: "prices.add")
        }
    }

    func update(_ entry: PriceEntry) async {
        Log.event("price update started", category: "prices.update", metadata: [
            "entryID": entry.id,
            "recordID": entry.recordID,
            "currency": entry.currency,
        ])
        do {
            try await database.execute(
                sql: """
                update price_entries set
                  price_cents = ?,
                  currency = ?,
                  shop_name = ?,
                  scanned_at = ?,
                  updated_at = ?
                where id = ?
                """,
                parameters: [
                    entry.priceCents,
                    entry.currency,
                    entry.shopName,
                    entry.scannedAt.iso8601,
                    Date().iso8601,
                    entry.id,
                ]
            )
            Log.event("price update completed", category: "prices.update", metadata: ["entryID": entry.id])
        } catch {
            Log.error(error, category: "prices.update")
        }
    }

    func delete(entryID: String) async {
        Log.event("price delete started", category: "prices.delete", metadata: ["entryID": entryID])
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: "update price_entries set deleted_at = ?, updated_at = ? where id = ?",
                parameters: [now, now, entryID]
            )
            Log.event("price delete completed", category: "prices.delete", metadata: ["entryID": entryID])
        } catch {
            Log.error(error, category: "prices.delete")
        }
    }
}
