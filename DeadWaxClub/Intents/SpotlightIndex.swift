import CoreSpotlight
import Foundation

/// Pushes record metadata into CoreSpotlight so users can find their records
/// from Spotlight, Lock Screen search, and Siri Knowledge.
enum SpotlightIndex {
    static let domain = "com.deadwaxclub.records"

    static func index(records: [VinylRecord]) {
        let items: [CSSearchableItem] = records.map { record in
            let attrs = CSSearchableItemAttributeSet(itemContentType: "public.audio")
            attrs.title = record.title
            attrs.contentDescription = record.artist
            if let cw = record.colourway, !cw.isEmpty {
                attrs.album = cw
            }
            if let year = record.year {
                attrs.contentCreationDate = Calendar.current.date(from: DateComponents(year: year))
            }
            attrs.keywords = [record.artist, record.colourway, record.barcode]
                .compactMap { $0 }

            // Local cached cover art makes the Spotlight result render with the
            // album art icon. Falls back to the default app icon otherwise.
            let localFile = CoverArtCache.localFile(for: record.id)
            if FileManager.default.fileExists(atPath: localFile.path) {
                attrs.thumbnailURL = localFile
            }

            let item = CSSearchableItem(
                uniqueIdentifier: record.id,
                domainIdentifier: domain,
                attributeSet: attrs
            )
            return item
        }

        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error { Log.error(error, category: "spotlight.index") }
        }
    }

    static func remove(recordIDs: [String]) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: recordIDs) { error in
            if let error { Log.error(error, category: "spotlight.remove") }
        }
    }

    static func clearAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }
}
