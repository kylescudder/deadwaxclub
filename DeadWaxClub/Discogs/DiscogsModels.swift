import Foundation

enum DiscogsModels {
    struct SearchResponse: Decodable {
        let results: [SearchResult]
    }

    struct SearchResult: Decodable {
        let id: Int64
        let type: String?
        let title: String?
        let year: String?
        let cover_image: String?
        let thumb: String?
        let barcode: [String]?
        let format: [String]?
        let label: [String]?
        let country: String?
        let catno: String?
        let formats: [Format]?
    }

    struct Release: Decodable {
        let id: Int64
        let title: String
        let year: Int?
        let artists: [Artist]?
        let images: [Image]?
        let formats: [Format]?
        let identifiers: [Identifier]?
        let notes: String?
    }

    struct Artist: Decodable {
        let name: String
    }

    struct Image: Decodable {
        let type: String?       // "primary" | "secondary"
        let uri: String
        let uri150: String?
    }

    struct Format: Decodable {
        let name: String?
        let qty: String?
        let descriptions: [String]?
        let text: String?       // often contains colourway, e.g. "Coke Bottle Clear"
    }

    struct Identifier: Decodable {
        let type: String?       // e.g. "Barcode"
        let value: String?
    }
}

struct DiscogsSearchResult: Identifiable, Equatable {
    let id: Int64
    let title: String       // "Architects - Holy Hell"
    let year: Int?
    let format: String?     // "Vinyl, LP, Album, Reissue"
    let label: String?
    let coverThumb: String?
    let barcode: String?
    let country: String?    // e.g. "Europe", "UK", "US"
    let catno: String?      // e.g. "7600-1"
    let colourway: String?  // e.g. "Coke Bottle Clear" — pulled from formats[].text
}

struct DiscogsLookup: Equatable {
    let releaseID: Int64
    let title: String
    let artist: String
    let year: Int?
    let colourway: String?
    let coverArtURL: String?
    let barcode: String?
    /// Median marketplace price reported by Discogs at the moment of lookup.
    /// Stored on the record as an estimate; clearly labelled in the UI as
    /// distinct from any user-recorded paid price.
    let estimatedPriceCents: Int?
    let estimatedCurrency: String?
}

extension DiscogsModels {
    struct MarketplaceStats: Decodable {
        struct Price: Decodable {
            let value: Double
            let currency: String
        }
        let lowest_price: Price?
        let median_price: Price?
        let highest_price: Price?
        let num_for_sale: Int?
    }
}
