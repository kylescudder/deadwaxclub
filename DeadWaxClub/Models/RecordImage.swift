import Foundation
import PowerSync

enum RecordImageKind: String, Codable {
    case discogs       = "discogs"
    case userUpload    = "user_upload"
}

struct RecordImage: Identifiable, Hashable {
    let id: String
    var recordID: String
    var collectionID: String
    var kind: RecordImageKind
    var position: Int
    /// Original upstream URL (e.g. Discogs CDN). Null for user-uploaded images.
    var sourceURL: String?
    /// Path inside the `covers` Supabase Storage bucket once the bytes are
    /// mirrored. Null until first sight uploads it.
    var storagePath: String?
    var uploadedBy: String?
    var createdAt: Date
}

extension RecordImage {
    static func from(cursor: SqlCursor) -> RecordImage? {
        do {
            let kindRaw = try cursor.getString(name: "kind")
            guard let kind = RecordImageKind(rawValue: kindRaw) else { return nil }
            return RecordImage(
                id: try cursor.getString(name: "id"),
                recordID: try cursor.getString(name: "record_id"),
                collectionID: try cursor.getString(name: "collection_id"),
                kind: kind,
                position: try cursor.getInt(name: "position"),
                sourceURL: try cursor.getStringOptional(name: "source_url"),
                storagePath: try cursor.getStringOptional(name: "storage_path"),
                uploadedBy: try cursor.getStringOptional(name: "uploaded_by"),
                createdAt: parseDate(try cursor.getStringOptional(name: "created_at")) ?? Date()
            )
        } catch {
            return nil
        }
    }
}
