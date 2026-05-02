import Foundation

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
    var ownerID: String
    var status: RecordStatus
    var title: String
    var artist: String
    var year: Int?
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
    static func from(row: [String: Any]) -> VinylRecord? {
        guard let id = row["id"] as? String,
              let ownerID = row["owner_id"] as? String,
              let statusRaw = row["status"] as? String,
              let status = RecordStatus(rawValue: statusRaw),
              let title = row["title"] as? String,
              let artist = row["artist"] as? String else {
            return nil
        }
        return VinylRecord(
            id: id,
            ownerID: ownerID,
            status: status,
            title: title,
            artist: artist,
            year: row["year"] as? Int,
            colourway: row["colourway"] as? String,
            coverArtSourceURL: row["cover_art_source_url"] as? String,
            coverArtStoragePath: row["cover_art_storage_path"] as? String,
            discogsReleaseID: row["discogs_release_id"] as? Int64,
            barcode: row["barcode"] as? String,
            notes: row["notes"] as? String,
            estimatedPriceCents: row["estimated_price_cents"] as? Int,
            estimatedPriceCurrency: row["estimated_price_currency"] as? String,
            estimatedPriceUpdatedAt: parseDate(row["estimated_price_updated_at"]),
            createdAt: parseDate(row["created_at"]) ?? Date(),
            updatedAt: parseDate(row["updated_at"]) ?? Date(),
            deletedAt: parseDate(row["deleted_at"])
        )
    }
}

func parseDate(_ value: Any?) -> Date? {
    guard let s = value as? String, !s.isEmpty else { return nil }
    return ISO8601DateFormatter.trackd.date(from: s)
        ?? ISO8601DateFormatter.trackdFractional.date(from: s)
}

extension ISO8601DateFormatter {
    static let trackd: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let trackdFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
