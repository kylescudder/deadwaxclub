import Foundation
import PowerSync

@MainActor
final class ListsRepository: ObservableObject {
    @Published private(set) var lists: [VinylList] = []

    private let database: PowerSyncDatabaseProtocol
    private let auth: AuthClient
    private var watchTask: Task<Void, Never>?

    init(database: PowerSyncDatabaseProtocol, auth: AuthClient) {
        self.database = database
        self.auth = auth
    }

    deinit { watchTask?.cancel() }

    func startWatching(userID: String) {
        watchTask?.cancel()
        watchTask = Task { [weak self, database] in
            guard let self else { return }
            // Lists owned by user OR lists where user is a member.
            let sql = """
            select distinct l.* from lists l
            left join list_members m on m.list_id = l.id
            where l.deleted_at is null
              and (l.owner_id = ? or m.user_id = ?)
            order by l.updated_at desc
            """
            do {
                for try await rows in database.watch(sql: sql, parameters: [userID, userID]) {
                    let mapped = rows.compactMap { VinylList.from(row: $0 as? [String: Any] ?? [:]) }
                    await MainActor.run { self.lists = mapped }
                }
            } catch {
                Log.error(error, category: "lists.watch")
            }
        }
    }

    func create(name: String, description: String?, mode: ListShareMode) async -> VinylList? {
        guard let ownerID = auth.currentUserID?.uuidString else { return nil }
        let now = Date()
        let id = UUID().uuidString.lowercased()
        let token: String? = (mode == .linkPublic) ? Self.makeShareToken() : nil
        let list = VinylList(
            id: id,
            ownerID: ownerID,
            name: name,
            description: description,
            shareMode: mode,
            shareToken: token,
            coverRecordID: nil,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )
        await upsert(list)
        return list
    }

    func upsert(_ list: VinylList) async {
        do {
            try await database.execute(
                sql: """
                insert into lists
                  (id, owner_id, name, description, share_mode, share_token,
                   cover_record_id, created_at, updated_at)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?)
                on conflict(id) do update set
                  name = excluded.name,
                  description = excluded.description,
                  share_mode = excluded.share_mode,
                  share_token = excluded.share_token,
                  cover_record_id = excluded.cover_record_id,
                  updated_at = excluded.updated_at
                """,
                parameters: [
                    list.id, list.ownerID, list.name, list.description as Any,
                    list.shareMode.rawValue, list.shareToken as Any,
                    list.coverRecordID as Any,
                    ISO8601DateFormatter.iso.string(from: list.createdAt),
                    ISO8601DateFormatter.iso.string(from: Date()),
                ]
            )
        } catch {
            Log.error(error, category: "lists.upsert")
        }
    }

    func updateShareMode(listID: String, mode: ListShareMode) async {
        let token: String? = (mode == .linkPublic) ? Self.makeShareToken() : nil
        do {
            try await database.execute(
                sql: """
                update lists set share_mode = ?, share_token = ?, updated_at = ? where id = ?
                """,
                parameters: [mode.rawValue, token as Any,
                             ISO8601DateFormatter.iso.string(from: Date()),
                             listID]
            )
        } catch {
            Log.error(error, category: "lists.updateShareMode")
        }
    }

    func softDelete(listID: String) async {
        do {
            let now = ISO8601DateFormatter.iso.string(from: Date())
            try await database.execute(
                sql: "update lists set deleted_at = ?, updated_at = ? where id = ?",
                parameters: [now, now, listID]
            )
        } catch {
            Log.error(error, category: "lists.softDelete")
        }
    }

    func addRecord(_ recordID: String, to listID: String) async {
        guard let userID = auth.currentUserID?.uuidString else { return }
        let id = UUID().uuidString.lowercased()
        let now = ISO8601DateFormatter.iso.string(from: Date())
        do {
            try await database.execute(
                sql: """
                insert into list_items (id, list_id, record_id, added_by, position, created_at)
                values (?, ?, ?, ?, coalesce((select max(position) + 1 from list_items where list_id = ?), 0), ?)
                on conflict(list_id, record_id) do nothing
                """,
                parameters: [id, listID, recordID, userID, listID, now]
            )
        } catch {
            Log.error(error, category: "lists.addRecord")
        }
    }

    func removeRecord(_ recordID: String, from listID: String) async {
        do {
            try await database.execute(
                sql: "delete from list_items where list_id = ? and record_id = ?",
                parameters: [listID, recordID]
            )
        } catch {
            Log.error(error, category: "lists.removeRecord")
        }
    }

    /// Members live in a separate table; collaborators / invitees only.
    func addMember(listID: String, userEmail: String, role: ListMemberRole) async throws {
        // Lookup user_id by email via Supabase RPC (auth.users isn't readable
        // directly from RLS-protected client). Falls back to error if no user.
        struct LookupResult: Decodable { let user_id: String? }
        let result: [LookupResult] = try await auth.supabase
            .rpc("lookup_user_id_by_email", params: ["email_in": userEmail])
            .execute()
            .value
        guard let userID = result.first?.user_id else {
            throw NSError(domain: "deadwaxclub.lists", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "No Dead Wax Club user found with that email."
            ])
        }
        try await auth.supabase
            .from("list_members")
            .upsert([
                "list_id": listID,
                "user_id": userID,
                "role": role.rawValue,
                "invited_by": auth.currentUserID?.uuidString as Any,
            ])
            .execute()
    }

    func removeMember(listID: String, userID: String) async {
        do {
            try await auth.supabase
                .from("list_members")
                .delete()
                .eq("list_id", value: listID)
                .eq("user_id", value: userID)
                .execute()
        } catch {
            Log.error(error, category: "lists.removeMember")
        }
    }

    private static func makeShareToken(length: Int = 12) -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }
}
