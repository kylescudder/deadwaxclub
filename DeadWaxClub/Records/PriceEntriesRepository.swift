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
        watchTask?.cancel()
        watchTask = Task { [weak self, database] in
            guard let self else { return }
            let sql = """
                select * from price_entries
                where record_id = ?
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
                    await MainActor.run { self.entries = mapped }
                }
            } catch {
                Log.error(error, category: "prices.watch")
            }
        }
    }

    func add(_ entry: PriceEntry) async {
        do {
            try await database.execute(
                sql: """
                insert into price_entries
                  (id, record_id, owner_id, collection_id, price_cents, currency, shop_name, scanned_at, created_at)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                ]
            )
        } catch {
            Log.error(error, category: "prices.add")
        }
    }

    func update(_ entry: PriceEntry) async {
        do {
            try await database.execute(
                sql: """
                update price_entries set
                  price_cents = ?,
                  currency = ?,
                  shop_name = ?,
                  scanned_at = ?
                where id = ?
                """,
                parameters: [
                    entry.priceCents,
                    entry.currency,
                    entry.shopName,
                    entry.scannedAt.iso8601,
                    entry.id,
                ]
            )
        } catch {
            Log.error(error, category: "prices.update")
        }
    }

    func delete(entryID: String) async {
        do {
            try await database.execute(
                sql: "delete from price_entries where id = ?",
                parameters: [entryID]
            )
        } catch {
            Log.error(error, category: "prices.delete")
        }
    }
}
