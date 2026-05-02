import Foundation
import PowerSync

/// Watches the records belonging to a single list, joined to list_items
/// so we get ordering. Used by ListDetailView.
@MainActor
final class ListContentsRepository: ObservableObject {
    @Published private(set) var records: [VinylRecord] = []
    @Published private(set) var members: [VinylListMember] = []

    private let database: PowerSyncDatabaseProtocol
    private var recordsTask: Task<Void, Never>?
    private var membersTask: Task<Void, Never>?

    init(database: PowerSyncDatabaseProtocol) {
        self.database = database
    }

    deinit {
        recordsTask?.cancel()
        membersTask?.cancel()
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
                for try await rows in database.watch(sql: sql, parameters: [listID]) {
                    let mapped = rows.compactMap { VinylRecord.from(row: $0 as? [String: Any] ?? [:]) }
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
                for try await rows in database.watch(sql: sql, parameters: [listID]) {
                    let mapped: [VinylListMember] = rows.compactMap { raw in
                        guard let r = raw as? [String: Any],
                              let listID = r["list_id"] as? String,
                              let userID = r["user_id"] as? String,
                              let roleRaw = r["role"] as? String,
                              let role = ListMemberRole(rawValue: roleRaw) else { return nil }
                        return VinylListMember(
                            listID: listID,
                            userID: userID,
                            role: role,
                            joinedAt: parseDate(r["joined_at"]) ?? Date()
                        )
                    }
                    await MainActor.run { self.members = mapped }
                }
            } catch {
                Log.error(error, category: "list.members")
            }
        }
    }
}
