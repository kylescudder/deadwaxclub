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
                for try await rows in database.watch(sql: sql, parameters: [ownerID, status.rawValue]) {
                    let mapped = rows.compactMap { VinylRecord.from(row: $0 as? [String: Any] ?? [:]) }
                    await MainActor.run {
                        self.records = mapped
                        self.isLoading = false
                    }
                }
            } catch {
                Log.error(error, category: "records.watch")
                await MainActor.run { self.isLoading = false }
            }
        }
    }

    func upsert(_ record: VinylRecord) async {
        do {
            try await database.execute(
                sql: """
                insert into records
                  (id, owner_id, status, title, artist, year, colourway,
                   cover_art_source_url, cover_art_storage_path,
                   discogs_release_id, barcode, notes, created_at, updated_at)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                on conflict(id) do update set
                  status = excluded.status,
                  title = excluded.title,
                  artist = excluded.artist,
                  year = excluded.year,
                  colourway = excluded.colourway,
                  cover_art_source_url = excluded.cover_art_source_url,
                  cover_art_storage_path = excluded.cover_art_storage_path,
                  discogs_release_id = excluded.discogs_release_id,
                  barcode = excluded.barcode,
                  notes = excluded.notes,
                  updated_at = excluded.updated_at
                """,
                parameters: [
                    record.id,
                    record.ownerID,
                    record.status.rawValue,
                    record.title,
                    record.artist,
                    record.year as Any,
                    record.colourway as Any,
                    record.coverArtSourceURL as Any,
                    record.coverArtStoragePath as Any,
                    record.discogsReleaseID as Any,
                    record.barcode as Any,
                    record.notes as Any,
                    ISO8601DateFormatter.trackd.string(from: record.createdAt),
                    ISO8601DateFormatter.trackd.string(from: Date()),
                ]
            )
        } catch {
            Log.error(error, category: "records.upsert")
        }
    }

    func updateStoragePath(recordID: String, storagePath: String) async {
        do {
            try await database.execute(
                sql: "update records set cover_art_storage_path = ?, updated_at = ? where id = ?",
                parameters: [storagePath, ISO8601DateFormatter.trackd.string(from: Date()), recordID]
            )
        } catch {
            Log.error(error, category: "records.updateStoragePath")
        }
    }

    func softDelete(recordID: String) async {
        do {
            let now = ISO8601DateFormatter.trackd.string(from: Date())
            try await database.execute(
                sql: "update records set deleted_at = ?, updated_at = ? where id = ?",
                parameters: [now, now, recordID]
            )
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
                parameters: [ownerID, barcode]
            )
            guard let row = rows.first as? [String: Any] else { return nil }
            return VinylRecord.from(row: row)
        } catch {
            Log.error(error, category: "records.findByBarcode")
            return nil
        }
    }
}
