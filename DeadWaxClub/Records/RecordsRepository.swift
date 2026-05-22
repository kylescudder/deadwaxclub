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

    /// Watch records the user can see — the union across every Collection
    /// they belong to (`collection_members.user_id = ?`). When `collectionID`
    /// is set, narrow further to that single Collection.
    func startWatching(status: RecordStatus, userID: String, collectionID: String? = nil) {
        watchTask?.cancel()
        isLoading = true
        watchTask = Task { [weak self, database] in
            guard let self else { return }
            let sql: String
            let params: [Any?]
            if let collectionID {
                sql = """
                    select * from records
                    where collection_id = ?
                      and collection_id in (select collection_id from collection_members where user_id = ?)
                      and status = ? and deleted_at is null
                    order by updated_at desc
                """
                params = [collectionID, userID, status.rawValue]
            } else {
                sql = """
                    select * from records
                    where collection_id in (select collection_id from collection_members where user_id = ?)
                      and status = ? and deleted_at is null
                    order by updated_at desc
                """
                params = [userID, status.rawValue]
            }
            do {
                let stream = try database.watch(
                    sql: sql,
                    parameters: params,
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
        let updatedAt = Date().iso8601
        let createdAt = record.createdAt.iso8601
        let estimatedAt = record.estimatedPriceUpdatedAt?.iso8601
        do {
            // PowerSync exposes tables as views — ON CONFLICT … DO UPDATE is
            // not supported. Insert-or-ignore then update covers both cases.
            try await database.execute(
                sql: """
                insert or ignore into records
                  (id, collection_id, status, title, artist, year, album_year, colourway,
                   cover_art_source_url, cover_art_storage_path,
                   discogs_release_id, barcode, notes,
                   estimated_price_cents, estimated_price_currency, estimated_price_updated_at,
                   created_at, updated_at)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                parameters: [
                    record.id,
                    record.collectionID,
                    record.status.rawValue,
                    record.title,
                    record.artist,
                    record.year,
                    record.albumYear,
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
                  collection_id = ?,
                  status = ?,
                  title = ?,
                  artist = ?,
                  year = ?,
                  album_year = ?,
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
                    record.collectionID,
                    record.status.rawValue,
                    record.title,
                    record.artist,
                    record.year,
                    record.albumYear,
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
            let now = Date().iso8601
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

    func updateStatus(recordID: String, status: RecordStatus) async {
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: "update records set status = ?, updated_at = ? where id = ?",
                parameters: [status.rawValue, now, recordID]
            )
        } catch {
            Log.error(error, category: "records.updateStatus")
        }
    }

    func updateStoragePath(recordID: String, storagePath: String) async {
        do {
            try await database.execute(
                sql: "update records set cover_art_storage_path = ?, updated_at = ? where id = ?",
                parameters: [storagePath, Date().iso8601, recordID]
            )
        } catch {
            Log.error(error, category: "records.updateStoragePath")
        }
    }

    func softDelete(recordID: String) async {
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: "update records set deleted_at = ?, updated_at = ? where id = ?",
                parameters: [now, now, recordID]
            )
            SpotlightIndex.remove(recordIDs: [recordID])
        } catch {
            Log.error(error, category: "records.softDelete")
        }
    }

    /// Look up an existing record by barcode across every Collection the user
    /// can see — prevents the same release being added twice when one member
    /// has it in a personal Collection and another scans it into a shared one.
    func findByBarcode(_ barcode: String, userID: String) async -> VinylRecord? {
        do {
            let rows = try await database.getAll(
                sql: """
                select * from records
                where collection_id in (select collection_id from collection_members where user_id = ?)
                  and barcode = ? and deleted_at is null
                limit 1
                """,
                parameters: [userID, barcode],
                mapper: { VinylRecord.from(cursor: $0) }
            )
            return rows.compactMap { $0 }.first
        } catch {
            Log.error(error, category: "records.findByBarcode")
            return nil
        }
    }

    func findDuplicate(
        title: String,
        artist: String,
        displayYear: Int?,
        colourway: String?,
        discogsReleaseID: Int64?,
        barcode: String?,
        userID: String,
        collectionID: String,
        excludingRecordID: String? = nil
    ) async -> VinylRecord? {
        if let discogsReleaseID,
           let match = await firstDuplicate(
            whereSQL: "discogs_release_id = ?",
            parameters: [discogsReleaseID],
            userID: userID,
            collectionID: collectionID,
            excludingRecordID: excludingRecordID
           ) {
            return match
        }

        let trimmedBarcode = barcode?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedBarcode, !trimmedBarcode.isEmpty,
           let match = await firstDuplicate(
            whereSQL: "barcode = ?",
            parameters: [trimmedBarcode],
            userID: userID,
            collectionID: collectionID,
            excludingRecordID: excludingRecordID
           ) {
            return match
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedTitle.isEmpty, !normalizedArtist.isEmpty else { return nil }

        let titleArtistColourwaySQL = """
        lower(trim(title)) = ?
          and lower(trim(artist)) = ?
          and lower(trim(coalesce(colourway, ''))) = ?
        """
        let titleArtistColourwayParameters: [Any?] = [
            normalizedTitle,
            normalizedArtist,
            (colourway ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ]

        var whereSQL = titleArtistColourwaySQL
        var parameters = titleArtistColourwayParameters
        if let displayYear {
            whereSQL += " and coalesce(album_year, year) = ?"
            parameters.append(displayYear)
        } else {
            whereSQL += " and coalesce(album_year, year) is null"
        }

        if let match = await firstDuplicate(
            whereSQL: whereSQL,
            parameters: parameters,
            userID: userID,
            collectionID: collectionID,
            excludingRecordID: excludingRecordID
        ) {
            return match
        }

        return await firstDuplicate(
            whereSQL: titleArtistColourwaySQL,
            parameters: titleArtistColourwayParameters,
            userID: userID,
            collectionID: collectionID,
            excludingRecordID: excludingRecordID
        )
    }

    private func firstDuplicate(
        whereSQL: String,
        parameters: [Any?],
        userID: String,
        collectionID: String,
        excludingRecordID: String?
    ) async -> VinylRecord? {
        do {
            var sql = """
            select * from records
            where collection_id = ?
              and collection_id in (select collection_id from collection_members where user_id = ?)
              and deleted_at is null
              and \(whereSQL)
            """
            var params: [Any?] = [collectionID, userID]
            params.append(contentsOf: parameters)
            if let excludingRecordID {
                sql += " and id <> ?"
                params.append(excludingRecordID)
            }
            sql += " order by case status when 'owned' then 0 else 1 end, updated_at desc limit 1"

            let rows = try await database.getAll(
                sql: sql,
                parameters: params,
                mapper: { VinylRecord.from(cursor: $0) }
            )
            return rows.compactMap { $0 }.first
        } catch {
            Log.error(error, category: "records.findDuplicate")
            return nil
        }
    }

    /// True iff a live (non-tombstoned) row exists in local SQLite for this
    /// record. Used by RecordDetailView to detect remote soft-deletes while
    /// the screen is still open, so we can pop back instead of leaving the
    /// user staring at a stale record.
    func exists(recordID: String) async -> Bool {
        do {
            let rows = try await database.getAll(
                sql: "select 1 from records where id = ? and deleted_at is null limit 1",
                parameters: [recordID],
                mapper: { _ in true }
            )
            return !rows.isEmpty
        } catch {
            Log.error(error, category: "records.exists")
            return true
        }
    }

    /// Move a record into a different Collection the user has write access to.
    func moveToCollection(recordID: String, collectionID: String) async {
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: "update records set collection_id = ?, updated_at = ? where id = ?",
                parameters: [collectionID, now, recordID]
            )
            try await database.execute(
                sql: "update price_entries set collection_id = ? where record_id = ?",
                parameters: [collectionID, recordID]
            )
        } catch {
            Log.error(error, category: "records.moveToCollection")
        }
    }
}
