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

    func startWatching(listID: String) {
        recordsTask?.cancel()
        recordsTask = Task { [weak self, database] in
            guard let self else { return }
            let sql = """
            select r.*, li.position
            from list_items li
            join records r on r.id = li.record_id
            where li.list_id = ? and r.deleted_at is null
            order by li.position asc, li.created_at asc
            """
            do {
                let stream = try database.watch(
                    sql: sql,
                    parameters: [listID],
                    mapper: { VinylRecord.from(cursor: $0) }
                )
                for try await rows in stream {
                    let mapped = rows.compactMap { $0 }
                    await MainActor.run { self.records = mapped }
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
