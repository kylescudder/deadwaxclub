import Foundation
import PowerSync
import CryptoKit

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
    var recordPressingID: String?
    var collectionID: String
    var createdBy: String?
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
                recordPressingID: try cursor.getStringOptional(name: "record_pressing_id"),
                collectionID: try cursor.getString(name: "collection_id"),
                createdBy: try cursor.getStringOptional(name: "created_by"),
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

    var coverCacheID: String {
        recordPressingID ?? id
    }

    var albumDedupeKey: String {
        AlbumIdentity.dedupeKey(
            title: title,
            artist: artist,
            albumYear: albumYear
        )
    }

    var pressingDedupeKey: String {
        let albumID = AlbumIdentity.stableID(for: albumDedupeKey)
        return RecordPressingIdentity.dedupeKey(
            albumID: albumID,
            year: year,
            colourway: colourway,
            discogsReleaseID: discogsReleaseID,
            barcode: barcode
        )
    }
}

enum AlbumIdentity {
    static func dedupeKey(
        title: String,
        artist: String,
        albumYear: Int?
    ) -> String {
        [
            "album",
            normalize(title),
            normalizeArtist(artist),
            albumYear.map(String.init) ?? "",
        ].joined(separator: ":")
    }

    static func stableID(for dedupeKey: String) -> String {
        StableCatalogIdentity.stableID(for: dedupeKey)
    }
}

enum RecordPressingIdentity {
    static func dedupeKey(
        albumID: String,
        year: Int?,
        colourway: String?,
        discogsReleaseID: Int64?,
        barcode: String?
    ) -> String {
        if let discogsReleaseID {
            return "discogs:\(discogsReleaseID)"
        }

        let normalizedBarcode = normalize(barcode)
        if !normalizedBarcode.isEmpty {
            return "barcode:\(normalizedBarcode)"
        }

        return [
            "pressing",
            albumID,
            normalize(colourway),
            year.map(String.init) ?? "",
        ].joined(separator: ":")
    }

    static func stableID(for dedupeKey: String) -> String {
        StableCatalogIdentity.stableID(for: dedupeKey)
    }
}

private enum StableCatalogIdentity {
    static func stableID(for dedupeKey: String) -> String {
        let digest = SHA256.hash(data: Data(dedupeKey.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x0f) | 0x80

        return String(
            format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
    }
}

private func normalize(_ value: String?) -> String {
    (value ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
}

private func normalizeArtist(_ value: String?) -> String {
    ArtistNameNormalizer.discogsSortName(value ?? "")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
}

enum ArtistNameNormalizer {
    static func discogsSortName(_ artist: String) -> String {
        let withoutNumericSuffix = stripTrailingDiscogsNumericSuffix(from: artist)
        let trimmed = withoutNumericSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixRange = trimmed.startIndex..<trimmed.index(trimmed.startIndex, offsetBy: Swift.min(4, trimmed.count))
        guard trimmed.range(of: "the ", options: [.caseInsensitive], range: prefixRange) != nil else {
            return trimmed
        }
        return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displayName(_ artist: String) -> String {
        stripTrailingDiscogsNumericSuffix(from: artist)
    }

    private static func stripTrailingDiscogsNumericSuffix(from artist: String) -> String {
        var trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.last == ")",
              let openParen = trimmed.lastIndex(of: "(") {
            let suffixStart = trimmed.index(after: openParen)
            let suffixEnd = trimmed.index(before: trimmed.endIndex)
            let suffix = trimmed[suffixStart..<suffixEnd]
            guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { break }
            let beforeSuffix = trimmed[..<openParen].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !beforeSuffix.isEmpty else { break }
            trimmed = beforeSuffix
        }
        return trimmed
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
