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
                let stream = try database.watch(
                    sql: sql,
                    parameters: [userID, userID],
                    mapper: { VinylList.from(cursor: $0) }
                )
                for try await rows in stream {
                    let mapped = rows.compactMap { $0 }
                    await MainActor.run { self.lists = mapped }
                }
            } catch {
                Log.error(error, category: "lists.watch")
            }
        }
    }

    func create(name: String, description: String?, mode: ListShareMode) async -> VinylList? {
        guard let ownerID = auth.currentUserID?.lowerUUID else { return nil }
        let now = Date()
        let id = UUID().lowerUUID
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
        let createdAt = list.createdAt.iso8601
        let updatedAt = Date().iso8601
        do {
            // PowerSync exposes tables as views — ON CONFLICT … DO UPDATE is
            // not supported. Insert-or-ignore then update covers both cases.
            try await database.execute(
                sql: """
                insert or ignore into lists
                  (id, owner_id, name, description, share_mode, share_token,
                   cover_record_id, created_at, updated_at)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                parameters: [
                    list.id, list.ownerID, list.name, list.description,
                    list.shareMode.rawValue, list.shareToken,
                    list.coverRecordID, createdAt, updatedAt,
                ]
            )
            try await database.execute(
                sql: """
                update lists set
                  name = ?,
                  description = ?,
                  share_mode = ?,
                  share_token = ?,
                  cover_record_id = ?,
                  updated_at = ?
                where id = ?
                """,
                parameters: [
                    list.name, list.description,
                    list.shareMode.rawValue, list.shareToken,
                    list.coverRecordID, updatedAt, list.id,
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
                parameters: [mode.rawValue, token,
                             Date().iso8601,
                             listID]
            )
        } catch {
            Log.error(error, category: "lists.updateShareMode")
        }
    }

    func softDelete(listID: String) async {
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: "update lists set deleted_at = ?, updated_at = ? where id = ?",
                parameters: [now, now, listID]
            )
        } catch {
            Log.error(error, category: "lists.softDelete")
        }
    }

    func addRecord(_ recordID: String, to listID: String) async {
        guard let userID = auth.currentUserID?.lowerUUID else { return }
        do {
            // PowerSync's INSTEAD-OF triggers expect plain `INSERT … VALUES`.
            // `INSERT … SELECT … WHERE NOT EXISTS` and `ON CONFLICT … DO
            // NOTHING` both silently no-op on the views, so do the dedupe
            // and the position lookup as separate read queries first.
            let alreadyOnList: Bool? = try await database.getOptional(
                sql: "select 1 from list_items where list_id = ? and record_id = ? limit 1",
                parameters: [listID, recordID],
                mapper: { _ in true }
            )
            if alreadyOnList == true { return }

            let nextPosition: Int = try await database.getOptional(
                sql: "select coalesce(max(position) + 1, 0) as next_pos from list_items where list_id = ?",
                parameters: [listID],
                mapper: { try $0.getInt(name: "next_pos") }
            ) ?? 0

            let id = UUID().lowerUUID
            let now = Date().iso8601
            try await database.execute(
                sql: """
                insert into list_items (id, list_id, record_id, added_by, position, created_at)
                values (?, ?, ?, ?, ?, ?)
                """,
                parameters: [id, listID, recordID, userID, nextPosition, now]
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

    enum InviteOutcome: Equatable {
        case added       // Email matched an existing user; they're now in list_members.
        case pending     // No account yet; stored in pending_invites and resolved on signup.
    }

    /// Calls the `invite_to_list` RPC which adds the user directly when they
    /// already have an account or stores a pending invite that auto-resolves
    /// when they sign up. Returns which path was taken so the caller can show
    /// "Added" vs "Invitation sent" accordingly.
    func invite(listID: String, email: String, role: ListMemberRole) async throws -> InviteOutcome {
        struct InviteResult: Decodable { let status: String }
        let result: InviteResult = try await auth.supabase
            .rpc("invite_to_list", params: [
                "p_list_id": listID,
                "p_email": email,
                "p_role": role.rawValue,
            ])
            .execute()
            .value
        switch result.status {
        case "added":   return .added
        case "pending": return .pending
        default:
            throw NSError(domain: "deadwaxclub.lists", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Unexpected invite response: \(result.status)"
            ])
        }
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

    func revokePendingInvite(inviteID: String) async {
        do {
            _ = try await auth.supabase
                .rpc("revoke_pending_invite", params: ["p_invite_id": inviteID])
                .execute()
        } catch {
            Log.error(error, category: "lists.revokePendingInvite")
        }
    }

    private static func makeShareToken(length: Int = 12) -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }
}
