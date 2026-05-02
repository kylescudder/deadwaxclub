import Foundation
import PowerSync

struct CollectionStats: Equatable {
    var ownedCount: Int
    var wishlistCount: Int
    var totalSpentCents: Int        // sum of latest paid price for each owned record
    var estimatedValueCents: Int    // sum of estimated_price for owned records
    var currency: String
    var byDecade: [DecadeBucket]
    var byColourway: [ColourwayBucket]
    var topPaid: [PaidEntry]
    var lowestSeen: [LowestEntry]
}

struct DecadeBucket: Identifiable, Equatable {
    var id: String { decade }
    var decade: String   // "1970s", "1980s"
    var count: Int
}

struct ColourwayBucket: Identifiable, Equatable {
    var id: String { colourway }
    var colourway: String
    var count: Int
}

struct PaidEntry: Identifiable, Equatable {
    var id: String { recordID }
    var recordID: String
    var title: String
    var artist: String
    var paidCents: Int
    var currency: String
}

struct LowestEntry: Identifiable, Equatable {
    var id: String { recordID }
    var recordID: String
    var title: String
    var artist: String
    var lowestCents: Int
    var currency: String
}

@MainActor
final class StatsRepository: ObservableObject {
    @Published private(set) var stats: CollectionStats?
    @Published private(set) var isLoading = false

    private let database: PowerSyncDatabaseProtocol

    init(database: PowerSyncDatabaseProtocol) {
        self.database = database
    }

    func refresh(ownerID: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let counts = countsByStatus(ownerID: ownerID)
            async let totalSpent = totalSpentCents(ownerID: ownerID)
            async let estimated = estimatedValueCents(ownerID: ownerID)
            async let decades = decadeBuckets(ownerID: ownerID)
            async let colourways = colourwayBuckets(ownerID: ownerID)
            async let topPaid = topPaidEntries(ownerID: ownerID, limit: 5)
            async let lowest = lowestSeenEntries(ownerID: ownerID, limit: 5)

            let (c, ts, ev, d, cw, tp, lo) = try await (counts, totalSpent, estimated, decades, colourways, topPaid, lowest)

            stats = CollectionStats(
                ownedCount: c.owned,
                wishlistCount: c.wishlist,
                totalSpentCents: ts.cents,
                estimatedValueCents: ev,
                currency: ts.currency ?? Locale.current.currency?.identifier ?? "GBP",
                byDecade: d,
                byColourway: cw,
                topPaid: tp,
                lowestSeen: lo
            )
        } catch {
            Log.error(error, category: "stats.refresh")
        }
    }

    private func countsByStatus(ownerID: String) async throws -> (owned: Int, wishlist: Int) {
        let rows = try await database.getAll(
            sql: """
            select status, count(*) as c
            from records
            where owner_id = ? and deleted_at is null
            group by status
            """,
            parameters: [ownerID]
        )
        var owned = 0, wishlist = 0
        for raw in rows {
            guard let row = raw as? [String: Any] else { continue }
            let count = (row["c"] as? Int) ?? 0
            if (row["status"] as? String) == "owned" { owned = count }
            else if (row["status"] as? String) == "wishlist" { wishlist = count }
        }
        return (owned, wishlist)
    }

    private func totalSpentCents(ownerID: String) async throws -> (cents: Int, currency: String?) {
        // Sum the latest price for each owned record. PowerSync's SQLite is
        // recent enough for a window-style subquery via correlated subselect.
        let rows = try await database.getAll(
            sql: """
            select sum(latest_price) as total, max(latest_currency) as cur
            from (
                select (
                    select pe.price_cents from price_entries pe
                    where pe.record_id = r.id
                    order by pe.scanned_at desc limit 1
                ) as latest_price,
                (
                    select pe.currency from price_entries pe
                    where pe.record_id = r.id
                    order by pe.scanned_at desc limit 1
                ) as latest_currency
                from records r
                where r.owner_id = ? and r.status = 'owned' and r.deleted_at is null
            )
            where latest_price is not null
            """,
            parameters: [ownerID]
        )
        let row = rows.first as? [String: Any]
        let total = (row?["total"] as? Int) ?? 0
        let currency = row?["cur"] as? String
        return (total, currency)
    }

    private func estimatedValueCents(ownerID: String) async throws -> Int {
        let rows = try await database.getAll(
            sql: """
            select coalesce(sum(estimated_price_cents), 0) as total
            from records
            where owner_id = ? and status = 'owned' and deleted_at is null
              and estimated_price_cents is not null
            """,
            parameters: [ownerID]
        )
        return ((rows.first as? [String: Any])?["total"] as? Int) ?? 0
    }

    private func decadeBuckets(ownerID: String) async throws -> [DecadeBucket] {
        let rows = try await database.getAll(
            sql: """
            select (year/10)*10 as decade_start, count(*) as c
            from records
            where owner_id = ? and status = 'owned' and deleted_at is null and year is not null
            group by decade_start
            order by decade_start asc
            """,
            parameters: [ownerID]
        )
        return rows.compactMap { raw in
            guard let row = raw as? [String: Any],
                  let start = row["decade_start"] as? Int,
                  let count = row["c"] as? Int else { return nil }
            return DecadeBucket(decade: "\(start)s", count: count)
        }
    }

    private func colourwayBuckets(ownerID: String) async throws -> [ColourwayBucket] {
        let rows = try await database.getAll(
            sql: """
            select colourway, count(*) as c
            from records
            where owner_id = ? and status = 'owned' and deleted_at is null
              and colourway is not null and colourway <> ''
            group by colourway
            order by c desc
            limit 8
            """,
            parameters: [ownerID]
        )
        return rows.compactMap { raw in
            guard let row = raw as? [String: Any],
                  let cw = row["colourway"] as? String,
                  let count = row["c"] as? Int else { return nil }
            return ColourwayBucket(colourway: cw, count: count)
        }
    }

    private func topPaidEntries(ownerID: String, limit: Int) async throws -> [PaidEntry] {
        let rows = try await database.getAll(
            sql: """
            select r.id, r.title, r.artist, pe.price_cents, pe.currency
            from records r
            join price_entries pe on pe.record_id = r.id
            where r.owner_id = ? and r.status = 'owned' and r.deleted_at is null
            order by pe.price_cents desc
            limit ?
            """,
            parameters: [ownerID, limit]
        )
        return rows.compactMap { raw in
            guard let row = raw as? [String: Any],
                  let id = row["id"] as? String,
                  let title = row["title"] as? String,
                  let artist = row["artist"] as? String,
                  let cents = row["price_cents"] as? Int,
                  let currency = row["currency"] as? String else { return nil }
            return PaidEntry(recordID: id, title: title, artist: artist, paidCents: cents, currency: currency)
        }
    }

    private func lowestSeenEntries(ownerID: String, limit: Int) async throws -> [LowestEntry] {
        let rows = try await database.getAll(
            sql: """
            select r.id, r.title, r.artist, min(pe.price_cents) as low, max(pe.currency) as currency
            from records r
            join price_entries pe on pe.record_id = r.id
            where r.owner_id = ? and r.status = 'wishlist' and r.deleted_at is null
            group by r.id, r.title, r.artist
            order by low asc
            limit ?
            """,
            parameters: [ownerID, limit]
        )
        return rows.compactMap { raw in
            guard let row = raw as? [String: Any],
                  let id = row["id"] as? String,
                  let title = row["title"] as? String,
                  let artist = row["artist"] as? String,
                  let cents = row["low"] as? Int,
                  let currency = row["currency"] as? String else { return nil }
            return LowestEntry(recordID: id, title: title, artist: artist, lowestCents: cents, currency: currency)
        }
    }
}
