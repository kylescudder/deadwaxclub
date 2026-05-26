import Foundation
import PowerSync

/// Watches the records, members, and outstanding invites belonging to a
/// single list. Used by ListDetailView and ShareListSheet.
@MainActor
final class ListContentsRepository: ObservableObject {
    @Published private(set) var records: [VinylRecord] = []
    @Published private(set) var members: [VinylListMember] = []
    @Published private(set) var pendingInvites: [PendingInvite] = []

    private let database: PowerSyncDatabaseProtocol
    private var recordsTask: Task<Void, Never>?
    private var membersTask: Task<Void, Never>?
    private var invitesTask: Task<Void, Never>?

    init(database: PowerSyncDatabaseProtocol) {
        self.database = database
    }

    deinit {
        recordsTask?.cancel()
        membersTask?.cancel()
        invitesTask?.cancel()
    }

    /// One-shot fetch for a set of record ids. Used by the list watcher to
    /// resolve list_items rows into full record rows without relying on a
    /// JOIN watch (which doesn't always re-fire when only one side changes).
    private func fetchRecords(ids: [String]) async -> [VinylRecord] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
        select
          r.id,
          r.record_pressing_id,
          r.collection_id,
          r.created_by,
          r.status,
          a.title,
          a.artist,
          rp.year,
          a.album_year,
          rp.colourway,
          rp.cover_art_source_url,
          rp.cover_art_storage_path,
          rp.discogs_release_id,
          rp.barcode,
          r.notes,
          rp.estimated_price_cents,
          rp.estimated_price_currency,
          rp.estimated_price_updated_at,
          r.created_at,
          r.updated_at,
          r.deleted_at
        from records r
        join record_pressings rp on rp.id = r.record_pressing_id
        join albums a on a.id = rp.album_id
        where r.id in (\(placeholders)) and r.deleted_at is null
        """
        do {
            let rows = try await database.getAll(
                sql: sql,
                parameters: ids,
                mapper: { VinylRecord.from(cursor: $0) }
            )
            return rows.compactMap { $0 }
        } catch {
            Log.error(error, category: "list.contents.fetchRecords")
            return []
        }
    }

    func startWatching(listID: String) {
        recordsTask?.cancel()
        recordsTask = Task { [weak self, database] in
            guard let self else { return }
            // PowerSync's watch invalidation can miss when only the
            // secondary table of a JOIN changes, so watch list_items by
            // itself and resolve records via a one-shot lookup.
            let itemsSQL = """
            select record_id, position, created_at
            from list_items
            where list_id = ?
            order by position asc, created_at asc
            """
            do {
                let stream = try database.watch(
                    sql: itemsSQL,
                    parameters: [listID],
                    mapper: { (cursor: SqlCursor) -> (id: String, position: Int)? in
                        do {
                            return (
                                id: try cursor.getString(name: "record_id"),
                                position: try cursor.getInt(name: "position")
                            )
                        } catch {
                            return nil
                        }
                    }
                )
                for try await rows in stream {
                    let items = rows.compactMap { $0 }
                    let ids = items.map { $0.id }
                    let resolved = await self.fetchRecords(ids: ids)
                    let ordered = items.compactMap { item in
                        resolved.first(where: { $0.id == item.id })
                    }
                    await MainActor.run { self.records = ordered }
                }
            } catch {
                Log.error(error, category: "list.contents")
            }
        }

        membersTask?.cancel()
        membersTask = Task { [weak self, database] in
            guard let self else { return }
            let sql = "select * from list_members where list_id = ?"
            do {
                let stream = try database.watch(
                    sql: sql,
                    parameters: [listID],
                    mapper: { (cursor: SqlCursor) -> VinylListMember? in
                        do {
                            let roleRaw = try cursor.getString(name: "role")
                            guard let role = ListMemberRole(rawValue: roleRaw) else { return nil }
                            return VinylListMember(
                                listID: try cursor.getString(name: "list_id"),
                                userID: try cursor.getString(name: "user_id"),
                                role: role,
                                joinedAt: parseDate(try cursor.getStringOptional(name: "joined_at")) ?? Date()
                            )
                        } catch {
                            return nil
                        }
                    }
                )
                for try await rows in stream {
                    let mapped = rows.compactMap { $0 }
                    await MainActor.run { self.members = mapped }
                }
            } catch {
                Log.error(error, category: "list.members")
            }
        }

        invitesTask?.cancel()
        invitesTask = Task { [weak self, database] in
            guard let self else { return }
            let sql = """
            select * from pending_invites
            where list_id = ? and accepted_at is null
            order by created_at desc
            """
            do {
                let stream = try database.watch(
                    sql: sql,
                    parameters: [listID],
                    mapper: { PendingInvite.from(cursor: $0) }
                )
                for try await rows in stream {
                    let mapped = rows.compactMap { $0 }
                    await MainActor.run { self.pendingInvites = mapped }
                }
            } catch {
                Log.error(error, category: "list.pendingInvites")
            }
        }
    }
}
