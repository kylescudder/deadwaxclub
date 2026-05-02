import AppIntents
import Foundation

/// AppIntents view of a record. Shows up in Shortcuts, Siri suggestions,
/// and Spotlight. The query implementation reads straight from the local
/// PowerSync SQLite database so it stays current without a network round-trip.
struct VinylRecordEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Vinyl record")
    }

    static var defaultQuery = VinylRecordQuery()

    let id: String
    let title: String
    let artist: String
    let year: Int?
    let colourway: String?
    let coverArtPath: String?

    var displayRepresentation: DisplayRepresentation {
        var subtitle = artist
        if let cw = colourway, !cw.isEmpty {
            subtitle += " · \(cw)"
        }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: image
        )
    }

    private var image: DisplayRepresentation.Image? {
        if let path = coverArtPath, let url = CoverArtCache.publicStorageURL(path: path) {
            return DisplayRepresentation.Image(url: url)
        }
        return DisplayRepresentation.Image(systemName: "opticaldisc")
    }
}

extension VinylRecordEntity {
    init(record: VinylRecord) {
        self.id = record.id
        self.title = record.title
        self.artist = record.artist
        self.year = record.year
        self.colourway = record.colourway
        self.coverArtPath = record.coverArtStoragePath
    }
}
