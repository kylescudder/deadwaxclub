import Foundation
import PowerSync

enum RecordStatus: String, CaseIterable, Codable, Identifiable {
    case owned, wishlist
    var id: String { rawValue }

    var label: String {
        switch self {
        case .owned:    return "Owned"
        case .wishlist: return "Wishlist"
        }
    }
}

struct VinylRecord: Identifiable, Hashable {
    let id: String
    var collectionID: String
    var status: RecordStatus
    var title: String
    var artist: String
    var year: Int?
    var albumYear: Int?
    var colourway: String?
    var coverArtSourceURL: String?
    var coverArtStoragePath: String?
    var discogsReleaseID: Int64?
    var barcode: String?
    var notes: String?
    var estimatedPriceCents: Int?
    var estimatedPriceCurrency: String?
    var estimatedPriceUpdatedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}

extension VinylRecord {
    static func from(cursor: SqlCursor) -> VinylRecord? {
        do {
            let statusRaw = try cursor.getString(name: "status")
            guard let status = RecordStatus(rawValue: statusRaw) else { return nil }
            return VinylRecord(
                id: try cursor.getString(name: "id"),
                collectionID: try cursor.getString(name: "collection_id"),
                status: status,
                title: try cursor.getString(name: "title"),
                artist: try cursor.getString(name: "artist"),
                year: try cursor.getIntOptional(name: "year"),
                albumYear: try cursor.getIntOptional(name: "album_year"),
                colourway: try cursor.getStringOptional(name: "colourway"),
                coverArtSourceURL: try cursor.getStringOptional(name: "cover_art_source_url"),
                coverArtStoragePath: try cursor.getStringOptional(name: "cover_art_storage_path"),
                discogsReleaseID: try cursor.getInt64Optional(name: "discogs_release_id"),
                barcode: try cursor.getStringOptional(name: "barcode"),
                notes: try cursor.getStringOptional(name: "notes"),
                estimatedPriceCents: try cursor.getIntOptional(name: "estimated_price_cents"),
                estimatedPriceCurrency: try cursor.getStringOptional(name: "estimated_price_currency"),
                estimatedPriceUpdatedAt: parseDate(try cursor.getStringOptional(name: "estimated_price_updated_at")),
                createdAt: parseDate(try cursor.getStringOptional(name: "created_at")) ?? Date(),
                updatedAt: parseDate(try cursor.getStringOptional(name: "updated_at")) ?? Date(),
                deletedAt: parseDate(try cursor.getStringOptional(name: "deleted_at"))
            )
        } catch {
            return nil
        }
    }

    var displayYear: Int? {
        albumYear ?? year
    }
}

func parseDate(_ value: String?) -> Date? {
    guard let s = value, !s.isEmpty else { return nil }
    return ISO8601DateFormatter.iso.date(from: s)
        ?? ISO8601DateFormatter.isoFractional.date(from: s)
}

extension ISO8601DateFormatter {
    // ISO8601DateFormatter is documented as thread-safe once configured,
    // but Foundation hasn't marked it Sendable. Pin both formatters as
    // immutable globals and tell the compiler we've reasoned about it.
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
