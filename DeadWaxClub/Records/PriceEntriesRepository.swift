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
                for try await rows in database.watch(sql: sql, parameters: [recordID]) {
                    let mapped = rows.compactMap { PriceEntry.from(row: $0 as? [String: Any] ?? [:]) }
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
                  (id, record_id, owner_id, price_cents, currency, shop_name, scanned_at, created_at)
                values (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                parameters: [
                    entry.id,
                    entry.recordID,
                    entry.ownerID,
                    entry.priceCents,
                    entry.currency,
                    entry.shopName as Any,
                    ISO8601DateFormatter.iso.string(from: entry.scannedAt),
                    ISO8601DateFormatter.iso.string(from: entry.createdAt),
                ]
            )
        } catch {
            Log.error(error, category: "prices.add")
        }
    }
}
