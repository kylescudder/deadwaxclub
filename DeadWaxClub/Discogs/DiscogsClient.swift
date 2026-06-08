import Foundation
import Security

@MainActor
final class DiscogsClient: ObservableObject {
    enum LookupError: LocalizedError {
        case missingToken
        case noResults
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .missingToken: return "Add a Discogs personal access token in Settings."
            case .noResults: return "No release found for that barcode."
            case .http(let code): return "Discogs error (HTTP \(code))."
            }
        }
    }

    private let session: URLSession
    private let base = URL(string: "https://api.discogs.com")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    var hasToken: Bool { (try? Keychain.read(key: "discogs.token"))?.isEmpty == false }

    func setToken(_ token: String) {
        try? Keychain.write(key: "discogs.token", value: token)
        Log.event("discogs token saved", category: "discogs.auth", metadata: ["tokenLength": token.count])
    }

    func clearToken() {
        try? Keychain.delete(key: "discogs.token")
        Log.breadcrumb("discogs token cleared", category: "discogs.auth")
    }

    private func token() throws -> String {
        guard let t = try Keychain.read(key: "discogs.token"), !t.isEmpty else {
            throw LookupError.missingToken
        }
        return t
    }

    /// Look up a release by EAN/UPC barcode.
    func lookup(barcode: String) async throws -> DiscogsLookup {
        Log.event("discogs barcode lookup started", category: "discogs.lookup", metadata: ["barcodeLength": barcode.count])
        let token = try token()

        var components = URLComponents(url: base.appendingPathComponent("database/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "barcode", value: barcode),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "format", value: "Vinyl"),
            URLQueryItem(name: "per_page", value: "1"),
        ]

        let search: DiscogsModels.SearchResponse = try await get(url: components.url!, token: token)
        Log.event("discogs barcode search completed", category: "discogs.lookup", metadata: ["resultCount": search.results.count])
        guard let first = search.results.first else { throw LookupError.noResults }

        let result = try await lookup(releaseID: first.id, token: token, fallbackBarcode: barcode)
        Log.event("discogs barcode lookup completed", category: "discogs.lookup", metadata: [
            "releaseID": result.releaseID,
            "imageCount": result.imageURLs.count,
            "hasEstimate": result.estimatedPriceCents != nil,
        ])
        return result
    }

    /// Free-text search by title and/or artist for vinyl releases. Returns
    /// up to 25 lightweight results suitable for a picker UI; fetch the full
    /// `release(id:)` once the user picks one.
    func search(title: String, artist: String) async throws -> [DiscogsSearchResult] {
        let token = try token()
        var components = URLComponents(url: base.appendingPathComponent("database/search"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "format", value: "Vinyl"),
            URLQueryItem(name: "per_page", value: "25"),
        ]
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespaces)
        Log.event("discogs text search started", category: "discogs.search", metadata: [
            "hasTitle": !trimmedTitle.isEmpty,
            "hasArtist": !trimmedArtist.isEmpty,
        ])
        if !trimmedTitle.isEmpty {
            items.append(URLQueryItem(name: "release_title", value: trimmedTitle))
        }
        if !trimmedArtist.isEmpty {
            items.append(URLQueryItem(name: "artist", value: trimmedArtist))
        }
        components.queryItems = items

        let resp: DiscogsModels.SearchResponse = try await get(url: components.url!, token: token)
        Log.event("discogs text search completed", category: "discogs.search", metadata: ["resultCount": resp.results.count])
        return resp.results.map { r in
            DiscogsSearchResult(
                id: r.id,
                title: r.title ?? "Untitled",
                year: r.year.flatMap(Int.init),
                format: r.format?.joined(separator: ", "),
                label: r.label?.first,
                coverThumb: r.thumb ?? r.cover_image,
                barcode: r.barcode?.first,
                country: r.country,
                catno: r.catno,
                colourway: Self.colourway(from: r.formats)
            )
        }
    }

    func release(id: Int64) async throws -> DiscogsLookup {
        Log.event("discogs release lookup started", category: "discogs.release", metadata: ["releaseID": id])
        let token = try token()
        let lookup = try await lookup(releaseID: id, token: token, fallbackBarcode: nil)
        Log.event("discogs release lookup completed", category: "discogs.release", metadata: [
            "releaseID": id,
            "imageCount": lookup.imageURLs.count,
            "hasEstimate": lookup.estimatedPriceCents != nil,
        ])
        return lookup
    }

    /// Fetch only the marketplace stats for an existing release, e.g. to
    /// refresh the estimated value on a record we already have locally.
    func marketplaceStats(releaseID: Int64) async throws -> (cents: Int, currency: String)? {
        Log.event("discogs marketplace stats started", category: "discogs.marketplace", metadata: ["releaseID": releaseID])
        let token = try token()
        let stats: DiscogsModels.MarketplaceStats? = try await optionalGet(
            url: base.appendingPathComponent("marketplace/stats/\(releaseID)"),
            token: token
        )
        let estimate = Self.estimate(from: stats)
        Log.event("discogs marketplace stats completed", category: "discogs.marketplace", metadata: [
            "releaseID": releaseID,
            "hasEstimate": estimate != nil,
        ])
        return estimate
    }

    /// Like `get` but returns nil on 404 / network error so optional
    /// endpoints (marketplace stats) don't fail the whole lookup.
    private func optionalGet<T: Decodable>(url: URL, token: String) async throws -> T? {
        do {
            return try await get(url: url, token: token) as T
        } catch LookupError.http(404) {
            return nil
        } catch {
            Log.error(error, category: "discogs.optional")
            return nil
        }
    }

    private func lookup(releaseID: Int64, token: String, fallbackBarcode: String?) async throws -> DiscogsLookup {
        Log.event("discogs release fetch started", category: "discogs.lookup", metadata: ["releaseID": releaseID])
        async let releaseTask: DiscogsModels.Release = get(
            url: base.appendingPathComponent("releases/\(releaseID)"),
            token: token
        )
        async let statsTask: DiscogsModels.MarketplaceStats? = optionalGet(
            url: base.appendingPathComponent("marketplace/stats/\(releaseID)"),
            token: token
        )

        let release = try await releaseTask
        let stats = try await statsTask
        let masterYear: Int?
        if let masterID = release.master_id {
            let master: DiscogsModels.Master? = try await optionalGet(
                url: base.appendingPathComponent("masters/\(masterID)"),
                token: token
            )
            masterYear = master?.year
        } else {
            masterYear = nil
        }

        let lookup = Self.map(
            release: release,
            stats: stats,
            fallbackBarcode: fallbackBarcode,
            masterYear: masterYear
        )
        Log.event("discogs release fetch completed", category: "discogs.lookup", metadata: [
            "releaseID": releaseID,
            "hasMasterYear": masterYear != nil,
            "imageCount": lookup.imageURLs.count,
        ])
        return lookup
    }

    private func get<T: Decodable>(url: URL, token: String) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        // Cloudflare's bot heuristics in front of api.discogs.com block UAs
        // that look automated (specifically the "+<URL>" suffix Discogs's
        // own docs suggest). Keep the UA simple to stay under that radar.
        req.setValue("DeadWaxClub/0.1", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        Log.event("discogs request started", category: "discogs.network", metadata: ["path": url.path])
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            Log.event("discogs request failed", category: "discogs.network", metadata: ["path": url.path, "statusCode": code])
            throw LookupError.http(code)
        }
        Log.event("discogs request completed", category: "discogs.network", metadata: ["path": url.path, "statusCode": http.statusCode])
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func map(
        release: DiscogsModels.Release,
        stats: DiscogsModels.MarketplaceStats?,
        fallbackBarcode: String?,
        masterYear: Int?
    ) -> DiscogsLookup {
        // Order: primary first, secondaries after in Discogs's own order.
        // Falls back to whatever's first if no image is explicitly tagged.
        let primaryURI = release.images?.first(where: { $0.type == "primary" })?.uri
            ?? release.images?.first?.uri
        let allURIs: [String] = {
            guard let images = release.images else { return [] }
            var out: [String] = []
            if let primary = images.first(where: { $0.type == "primary" }) {
                out.append(primary.uri)
                out.append(contentsOf: images.filter { $0.type != "primary" }.map(\.uri))
            } else {
                out.append(contentsOf: images.map(\.uri))
            }
            // Dedupe while preserving order.
            var seen: Set<String> = []
            return out.filter { seen.insert($0).inserted }
        }()

        let barcode = release.identifiers?
            .first(where: { ($0.type ?? "").lowercased() == "barcode" })?.value
            ?? fallbackBarcode

        let colourway = colourway(from: release.formats)

        let artist = release.artists?
            .map { $0.name.replacingOccurrences(of: " (\\d+)", with: "", options: .regularExpression) }
            .joined(separator: ", ")
            ?? "Unknown artist"

        let estimate = estimate(from: stats)

        return DiscogsLookup(
            releaseID: release.id,
            title: release.title,
            artist: artist.isEmpty ? "Unknown artist" : artist,
            year: release.year,
            albumYear: masterYear,
            colourway: colourway,
            coverArtURL: primaryURI,
            imageURLs: allURIs,
            barcode: barcode,
            estimatedPriceCents: estimate?.cents,
            estimatedCurrency: estimate?.currency
        )
    }

    static func estimate(from stats: DiscogsModels.MarketplaceStats?) -> (cents: Int, currency: String)? {
        guard let stats, let median = stats.median_price ?? stats.lowest_price else { return nil }
        return (Int((median.value * 100).rounded()), median.currency)
    }

    private static func colourway(from formats: [DiscogsModels.Format]?) -> String? {
        guard let formats else { return nil }
        for f in formats {
            // `text` is the most reliable colourway field; otherwise look in descriptions.
            if let text = f.text, !text.isEmpty { return text }
            if let descs = f.descriptions {
                let candidates = descs.filter { desc in
                    let lower = desc.lowercased()
                    return !["lp", "ep", "12\"", "10\"", "7\"", "album", "reissue", "limited edition", "stereo", "mono"].contains(lower)
                }
                if let first = candidates.first { return first }
            }
        }
        return nil
    }
}
