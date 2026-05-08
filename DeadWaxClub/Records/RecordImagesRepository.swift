import Foundation
import PowerSync

@MainActor
final class RecordImagesRepository: ObservableObject {
    @Published private(set) var images: [RecordImage] = []

    private let database: PowerSyncDatabaseProtocol
    private var watchTask: Task<Void, Never>?

    init(database: PowerSyncDatabaseProtocol) {
        self.database = database
    }

    deinit { watchTask?.cancel() }

    /// Watch every image attached to a record, ordered by position.
    func startWatching(recordID: String) {
        watchTask?.cancel()
        watchTask = Task { [weak self, database] in
            guard let self else { return }
            let sql = """
                select * from record_images
                where record_id = ?
                order by position asc, created_at asc
            """
            do {
                let stream = try database.watch(
                    sql: sql,
                    parameters: [recordID],
                    mapper: { RecordImage.from(cursor: $0) }
                )
                for try await rows in stream {
                    let mapped = rows.compactMap { $0 }
                    await MainActor.run { self.images = mapped }
                }
            } catch {
                Log.error(error, category: "recordImages.watch")
            }
        }
    }

    /// Bulk insert from a Discogs lookup. Skips images that are already on
    /// the record (matched by source_url) so re-applying a Discogs result
    /// doesn't duplicate rows.
    func bulkInsertFromDiscogs(
        recordID: String,
        collectionID: String,
        sourceURLs: [String]
    ) async {
        guard !sourceURLs.isEmpty else { return }
        do {
            let existing: [String] = try await database.getAll(
                sql: "select source_url from record_images where record_id = ? and source_url is not null",
                parameters: [recordID],
                mapper: { try $0.getString(name: "source_url") }
            )
            let existingSet = Set(existing)
            let nextPositionStart: Int = (try? await database.getOptional(
                sql: "select coalesce(max(position) + 1, 0) as next from record_images where record_id = ?",
                parameters: [recordID],
                mapper: { try $0.getInt(name: "next") }
            )) ?? 0

            var pos = nextPositionStart
            let now = ISO8601DateFormatter.iso.string(from: Date())
            for url in sourceURLs where !existingSet.contains(url) {
                let id = UUID().uuidString.lowercased()
                try await database.execute(
                    sql: """
                    insert into record_images
                      (id, record_id, collection_id, kind, position, source_url, created_at)
                    values (?, ?, ?, 'discogs', ?, ?, ?)
                    """,
                    parameters: [id, recordID, collectionID, pos, url, now]
                )
                pos += 1
            }
        } catch {
            Log.error(error, category: "recordImages.bulkInsertFromDiscogs")
        }
    }

    /// Insert a single user-uploaded image (storage_path already populated by
    /// CoverArtCache.uploadUserImage). Returns the new image id.
    @discardableResult
    func insertUserUpload(
        recordID: String,
        collectionID: String,
        storagePath: String,
        uploadedBy: String,
        imageID: String? = nil
    ) async -> String? {
        do {
            let id = imageID ?? UUID().uuidString.lowercased()
            let now = ISO8601DateFormatter.iso.string(from: Date())
            let nextPos: Int = (try? await database.getOptional(
                sql: "select coalesce(max(position) + 1, 0) as next from record_images where record_id = ?",
                parameters: [recordID],
                mapper: { try $0.getInt(name: "next") }
            )) ?? 0
            try await database.execute(
                sql: """
                insert into record_images
                  (id, record_id, collection_id, kind, position, storage_path, uploaded_by, created_at)
                values (?, ?, ?, 'user_upload', ?, ?, ?, ?)
                """,
                parameters: [id, recordID, collectionID, nextPos, storagePath, uploadedBy, now]
            )
            return id
        } catch {
            Log.error(error, category: "recordImages.insertUserUpload")
            return nil
        }
    }

    /// Update storage_path after CoverArtCache.mirrorIfNeeded completes.
    func updateStoragePath(imageID: String, storagePath: String) async {
        do {
            try await database.execute(
                sql: "update record_images set storage_path = ? where id = ?",
                parameters: [storagePath, imageID]
            )
        } catch {
            Log.error(error, category: "recordImages.updateStoragePath")
        }
    }

    func delete(imageID: String) async {
        do {
            try await database.execute(
                sql: "delete from record_images where id = ?",
                parameters: [imageID]
            )
        } catch {
            Log.error(error, category: "recordImages.delete")
        }
    }
}
