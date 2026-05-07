import Foundation
import PowerSync

@MainActor
final class RecordsRepository: ObservableObject {
    @Published private(set) var records: [VinylRecord] = []
    @Published private(set) var isLoading = false

    private let database: PowerSyncDatabaseProtocol
    private var watchTask: Task<Void, Never>?

    init(database: PowerSyncDatabaseProtocol) {
        self.database = database
    }

    deinit { watchTask?.cancel() }

    func startWatching(status: RecordStatus, ownerID: String) {
        watchTask?.cancel()
        isLoading = true
        watchTask = Task { [weak self, database] in
            guard let self else { return }
            let sql = """
                select * from records
                where owner_id = ? and status = ? and deleted_at is null
                order by updated_at desc
            """
            do {
                let stream = try database.watch(
                    sql: sql,
                    parameters: [ownerID, status.rawValue],
                    mapper: { VinylRecord.from(cursor: $0) }
                )
                for try await rows in stream {
                    let mapped = rows.compactMap { $0 }
                    await MainActor.run {
                        self.records = mapped
                        self.isLoading = false
                        SpotlightIndex.index(records: mapped)
                    }
                }
            } catch {
                Log.error(error, category: "records.watch")
                await MainActor.run { self.isLoading = false }
            }
        }
    }

    func upsert(_ record: VinylRecord) async {
        let updatedAt = ISO8601DateFormatter.iso.string(from: Date())
        let createdAt = ISO8601DateFormatter.iso.string(from: record.createdAt)
        let estimatedAt = record.estimatedPriceUpdatedAt.map(ISO8601DateFormatter.iso.string(from:))
        do {
            // PowerSync exposes tables as views — ON CONFLICT … DO UPDATE is
            // not supported. Insert-or-ignore then update covers both cases.
            try await database.execute(
                sql: """
                insert or ignore into records
                  (id, owner_id, status, title, artist, year, colourway,
                   cover_art_source_url, cover_art_storage_path,
                   discogs_release_id, barcode, notes,
                   estimated_price_cents, estimated_price_currency, estimated_price_updated_at,
                   created_at, updated_at)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                parameters: [
                    record.id,
                    record.ownerID,
                    record.status.rawValue,
                    record.title,
                    record.artist,
                    record.year,
                    record.colourway,
                    record.coverArtSourceURL,
                    record.coverArtStoragePath,
                    record.discogsReleaseID,
                    record.barcode,
                    record.notes,
                    record.estimatedPriceCents,
                    record.estimatedPriceCurrency,
                    estimatedAt,
                    createdAt,
                    updatedAt,
                ]
            )
            try await database.execute(
                sql: """
                update records set
                  status = ?,
                  title = ?,
                  artist = ?,
                  year = ?,
                  colourway = ?,
                  cover_art_source_url = ?,
                  cover_art_storage_path = ?,
                  discogs_release_id = ?,
                  barcode = ?,
                  notes = ?,
                  estimated_price_cents = ?,
                  estimated_price_currency = ?,
                  estimated_price_updated_at = ?,
                  updated_at = ?
                where id = ?
                """,
                parameters: [
                    record.status.rawValue,
                    record.title,
                    record.artist,
                    record.year,
                    record.colourway,
                    record.coverArtSourceURL,
                    record.coverArtStoragePath,
                    record.discogsReleaseID,
                    record.barcode,
                    record.notes,
                    record.estimatedPriceCents,
                    record.estimatedPriceCurrency,
                    estimatedAt,
                    updatedAt,
                    record.id,
                ]
            )
        } catch {
            Log.error(error, category: "records.upsert")
        }
    }

    func updateEstimate(recordID: String, cents: Int, currency: String) async {
        do {
            let now = ISO8601DateFormatter.iso.string(from: Date())
            try await database.execute(
                sql: """
                update records set
                  estimated_price_cents = ?,
                  estimated_price_currency = ?,
                  estimated_price_updated_at = ?,
                  updated_at = ?
                where id = ?
                """,
                parameters: [cents, currency, now, now, recordID]
            )
        } catch {
            Log.error(error, category: "records.updateEstimate")
        }
    }

    func updateStoragePath(recordID: String, storagePath: String) async {
        do {
            try await database.execute(
                sql: "update records set cover_art_storage_path = ?, updated_at = ? where id = ?",
                parameters: [storagePath, ISO8601DateFormatter.iso.string(from: Date()), recordID]
            )
        } catch {
            Log.error(error, category: "records.updateStoragePath")
        }
    }

    func softDelete(recordID: String) async {
        do {
            let now = ISO8601DateFormatter.iso.string(from: Date())
            try await database.execute(
                sql: "update records set deleted_at = ?, updated_at = ? where id = ?",
                parameters: [now, now, recordID]
            )
            SpotlightIndex.remove(recordIDs: [recordID])
        } catch {
            Log.error(error, category: "records.softDelete")
        }
    }

    func findByBarcode(_ barcode: String, ownerID: String) async -> VinylRecord? {
        do {
            let rows = try await database.getAll(
                sql: """
                select * from records
                where owner_id = ? and barcode = ? and deleted_at is null
                limit 1
                """,
                parameters: [ownerID, barcode],
                mapper: { VinylRecord.from(cursor: $0) }
            )
            return rows.compactMap { $0 }.first
        } catch {
            Log.error(error, category: "records.findByBarcode")
            return nil
        }
    }
}
