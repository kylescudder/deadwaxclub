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

/// Stats are scoped to either every collection the user belongs to (default —
/// the union shown in the Records tab) or one specific collection picked from
/// the Stats screen.
enum StatsScope: Equatable {
    case allMyCollections(userID: String)
    case singleCollection(collectionID: String)
}

@MainActor
final class StatsRepository: ObservableObject {
    @Published private(set) var stats: CollectionStats?
    @Published private(set) var isLoading = false

    private let database: PowerSyncDatabaseProtocol

    init(database: PowerSyncDatabaseProtocol) {
        self.database = database
    }

    func refresh(scope: StatsScope) async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let counts = countsByStatus(scope: scope)
            async let totalSpent = totalSpentCents(scope: scope)
            async let estimated = estimatedValueCents(scope: scope)
            async let decades = decadeBuckets(scope: scope)
            async let colourways = colourwayBuckets(scope: scope)
            async let topPaid = topPaidEntries(scope: scope, limit: 5)
            async let lowest = lowestSeenEntries(scope: scope, limit: 5)

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

    /// Returns the SQL fragment + bound parameter for filtering records to
    /// the active scope. Both branches resolve to a single `?` parameter so
    /// callers can prepend it to the rest of their parameter list.
    private func scopeClause(_ scope: StatsScope) -> (String, Any) {
        switch scope {
        case .allMyCollections(let userID):
            return (
                "collection_id in (select collection_id from collection_members where user_id = ?)",
                userID
            )
        case .singleCollection(let collectionID):
            return ("collection_id = ?", collectionID)
        }
    }

    private func countsByStatus(scope: StatsScope) async throws -> (owned: Int, wishlist: Int) {
        struct Row { let status: String; let count: Int }
        let (where_, param) = scopeClause(scope)
        let rows = try await database.getAll(
            sql: """
            select status, count(*) as c
            from records
            where \(where_) and deleted_at is null
            group by status
            """,
            parameters: [param],
            mapper: { cursor -> Row? in
                guard let status = try? cursor.getString(name: "status"),
                      let c = try? cursor.getInt(name: "c") else { return nil }
                return Row(status: status, count: c)
            }
        )
        var owned = 0, wishlist = 0
        for row in rows.compactMap({ $0 }) {
            if row.status == "owned" { owned = row.count }
            else if row.status == "wishlist" { wishlist = row.count }
        }
        return (owned, wishlist)
    }

    private func totalSpentCents(scope: StatsScope) async throws -> (cents: Int, currency: String?) {
        struct Row { let total: Int; let currency: String? }
        let (where_, param) = scopeClause(scope)
        // Single window-function pass instead of two correlated subqueries
        // per record. Picks the most recent price_entry per record, joins the
        // owned-records filter, sums.
        let rows = try await database.getAll(
            sql: """
            select sum(latest.price_cents) as total, max(latest.currency) as cur
            from (
                select pe.record_id, pe.price_cents, pe.currency,
                       row_number() over (
                           partition by pe.record_id
                           order by pe.scanned_at desc
                       ) as rn
                from price_entries pe
                join records r on r.id = pe.record_id
                where r.\(where_) and r.status = 'owned' and r.deleted_at is null
                  and pe.deleted_at is null
            ) latest
            where latest.rn = 1
            """,
            parameters: [param],
            mapper: { cursor -> Row in
                let total = (try? cursor.getIntOptional(name: "total")).flatMap { $0 } ?? 0
                let currency = (try? cursor.getStringOptional(name: "cur")).flatMap { $0 }
                return Row(total: total, currency: currency)
            }
        )
        let row = rows.first
        return (row?.total ?? 0, row?.currency)
    }

    private func estimatedValueCents(scope: StatsScope) async throws -> Int {
        let (where_, param) = scopeClause(scope)
        let rows = try await database.getAll(
            sql: """
            select coalesce(sum(estimated_price_cents), 0) as total
            from records
            where \(where_) and status = 'owned' and deleted_at is null
              and estimated_price_cents is not null
            """,
            parameters: [param],
            mapper: { cursor in (try? cursor.getInt(name: "total")) ?? 0 }
        )
        return rows.first ?? 0
    }

    private func decadeBuckets(scope: StatsScope) async throws -> [DecadeBucket] {
        let (where_, param) = scopeClause(scope)
        let rows = try await database.getAll(
            sql: """
            select (year/10)*10 as decade_start, count(*) as c
            from records
            where \(where_) and status = 'owned' and deleted_at is null and year is not null
            group by decade_start
            order by decade_start asc
            """,
            parameters: [param],
            mapper: { cursor -> DecadeBucket? in
                guard let start = try? cursor.getInt(name: "decade_start"),
                      let count = try? cursor.getInt(name: "c") else { return nil }
                return DecadeBucket(decade: "\(start)s", count: count)
            }
        )
        return rows.compactMap { $0 }
    }

    private func colourwayBuckets(scope: StatsScope) async throws -> [ColourwayBucket] {
        let (where_, param) = scopeClause(scope)
        let rows = try await database.getAll(
            sql: """
            select colourway, count(*) as c
            from records
            where \(where_) and status = 'owned' and deleted_at is null
              and colourway is not null and colourway <> ''
            group by colourway
            order by c desc
            limit 8
            """,
            parameters: [param],
            mapper: { cursor -> ColourwayBucket? in
                guard let cw = try? cursor.getString(name: "colourway"),
                      let count = try? cursor.getInt(name: "c") else { return nil }
                return ColourwayBucket(colourway: cw, count: count)
            }
        )
        return rows.compactMap { $0 }
    }

    private func topPaidEntries(scope: StatsScope, limit: Int) async throws -> [PaidEntry] {
        let (where_, param) = scopeClause(scope)
        // Group by record so a record with multiple price entries shows up
        // once at its highest paid price — without this the same record
        // surfaces N times for N entries, as in #20. Soft-deleted records
        // (r.deleted_at) and tombstoned entries (pe.deleted_at) are both
        // excluded.
        let rows = try await database.getAll(
            sql: """
            select r.id, r.title, r.artist,
                   max(pe.price_cents) as price_cents,
                   max(pe.currency) as currency
            from records r
            join price_entries pe on pe.record_id = r.id
            where r.\(where_) and r.status = 'owned' and r.deleted_at is null
              and pe.deleted_at is null
            group by r.id, r.title, r.artist
            order by price_cents desc
            limit ?
            """,
            parameters: [param, limit],
            mapper: { cursor -> PaidEntry? in
                guard let id = try? cursor.getString(name: "id"),
                      let title = try? cursor.getString(name: "title"),
                      let artist = try? cursor.getString(name: "artist"),
                      let cents = try? cursor.getInt(name: "price_cents"),
                      let currency = try? cursor.getString(name: "currency") else { return nil }
                return PaidEntry(recordID: id, title: title, artist: artist, paidCents: cents, currency: currency)
            }
        )
        return rows.compactMap { $0 }
    }

    private func lowestSeenEntries(scope: StatsScope, limit: Int) async throws -> [LowestEntry] {
        let (where_, param) = scopeClause(scope)
        let rows = try await database.getAll(
            sql: """
            select r.id, r.title, r.artist, min(pe.price_cents) as low, max(pe.currency) as currency
            from records r
            join price_entries pe on pe.record_id = r.id
            where r.\(where_) and r.status = 'wishlist' and r.deleted_at is null
              and pe.deleted_at is null
            group by r.id, r.title, r.artist
            order by low asc
            limit ?
            """,
            parameters: [param, limit],
            mapper: { cursor -> LowestEntry? in
                guard let id = try? cursor.getString(name: "id"),
                      let title = try? cursor.getString(name: "title"),
                      let artist = try? cursor.getString(name: "artist"),
                      let cents = try? cursor.getInt(name: "low"),
                      let currency = try? cursor.getString(name: "currency") else { return nil }
                return LowestEntry(recordID: id, title: title, artist: artist, lowestCents: cents, currency: currency)
            }
        )
        return rows.compactMap { $0 }
    }
}
