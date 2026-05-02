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
    }

    func clearToken() {
        try? Keychain.delete(key: "discogs.token")
    }

    private func token() throws -> String {
        guard let t = try Keychain.read(key: "discogs.token"), !t.isEmpty else {
            throw LookupError.missingToken
        }
        return t
    }

    /// Look up a release by EAN/UPC barcode.
    func lookup(barcode: String) async throws -> DiscogsLookup {
        let token = try token()

        var components = URLComponents(url: base.appendingPathComponent("database/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "barcode", value: barcode),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "format", value: "Vinyl"),
            URLQueryItem(name: "per_page", value: "1"),
        ]

        let search: DiscogsModels.SearchResponse = try await get(url: components.url!, token: token)
        guard let first = search.results.first else { throw LookupError.noResults }

        async let release: DiscogsModels.Release = get(
            url: base.appendingPathComponent("releases/\(first.id)"),
            token: token
        )
        async let stats: DiscogsModels.MarketplaceStats? = optionalGet(
            url: base.appendingPathComponent("marketplace/stats/\(first.id)"),
            token: token
        )
        return try await Self.map(release: release, stats: stats, fallbackBarcode: barcode)
    }

    func release(id: Int64) async throws -> DiscogsLookup {
        let token = try token()
        async let release: DiscogsModels.Release = get(
            url: base.appendingPathComponent("releases/\(id)"),
            token: token
        )
        async let stats: DiscogsModels.MarketplaceStats? = optionalGet(
            url: base.appendingPathComponent("marketplace/stats/\(id)"),
            token: token
        )
        return try await Self.map(release: release, stats: stats, fallbackBarcode: nil)
    }

    /// Fetch only the marketplace stats for an existing release, e.g. to
    /// refresh the estimated value on a record we already have locally.
    func marketplaceStats(releaseID: Int64) async throws -> (cents: Int, currency: String)? {
        let token = try token()
        let stats: DiscogsModels.MarketplaceStats? = try await optionalGet(
            url: base.appendingPathComponent("marketplace/stats/\(releaseID)"),
            token: token
        )
        return Self.estimate(from: stats)
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

    private func get<T: Decodable>(url: URL, token: String) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        req.setValue("Trackd/0.1 +https://github.com/kylescudder/trackd", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LookupError.http(code)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func map(
        release: DiscogsModels.Release,
        stats: DiscogsModels.MarketplaceStats?,
        fallbackBarcode: String?
    ) -> DiscogsLookup {
        let cover = release.images?.first(where: { $0.type == "primary" })?.uri
            ?? release.images?.first?.uri

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
            colourway: colourway,
            coverArtURL: cover,
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
