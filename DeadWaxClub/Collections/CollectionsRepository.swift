import Foundation
import PowerSync

/// Watches every Collection the user belongs to plus its members and pending
/// invites. Mirrors `ListsRepository`. Writes to `collections` flow through
/// PowerSync's CRUD queue; membership changes go via Supabase RPC because
/// `collection_members` is read-only locally (composite PK + computed `id`).
@MainActor
final class CollectionsRepository: ObservableObject {
    @Published private(set) var collections: [VinylCollection] = []
    @Published private(set) var members: [CollectionMember] = []
    @Published private(set) var pendingInvites: [CollectionPendingInvite] = []
    @Published private(set) var memberProfilesByID: [String: CollectionMemberProfile] = [:]

    private let database: PowerSyncDatabaseProtocol
    private let auth: AuthClient
    private var collectionsTask: Task<Void, Never>?
    private var membersTask: Task<Void, Never>?
    private var invitesTask: Task<Void, Never>?
    private var refreshedProfileCollectionIDs: Set<String> = []

    init(database: PowerSyncDatabaseProtocol, auth: AuthClient) {
        self.database = database
        self.auth = auth
    }

    deinit {
        collectionsTask?.cancel()
        membersTask?.cancel()
        invitesTask?.cancel()
    }

    func startWatching(userID: String) {
        Log.breadcrumb("collections watch starting", category: "collections.watch")
        watchCollections(userID: userID)
        watchMembers(userID: userID)
        watchPendingInvites(userID: userID)
    }

    func stopWatching() {
        Log.breadcrumb("collections watch stopping", category: "collections.watch")
        collectionsTask?.cancel(); collectionsTask = nil
        membersTask?.cancel(); membersTask = nil
        invitesTask?.cancel(); invitesTask = nil
        collections = []
        members = []
        pendingInvites = []
        memberProfilesByID = [:]
        refreshedProfileCollectionIDs = []
    }

    func members(of collectionID: String) -> [CollectionMember] {
        members.filter { $0.collectionID == collectionID }
    }

    func pendingInvites(for collectionID: String) -> [CollectionPendingInvite] {
        pendingInvites.filter { $0.collectionID == collectionID }
    }

    func role(in collectionID: String, userID: String) -> CollectionMemberRole? {
        members.first(where: { $0.collectionID == collectionID && $0.userID == userID })?.role
    }

    func displayName(for userID: String) -> String? {
        let trimmed = memberProfilesByID[userID]?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func watchCollections(userID: String) {
        collectionsTask?.cancel()
        collectionsTask = Task { [weak self, database] in
            guard let self else { return }
            let sql = """
            select c.* from collections c
            join collection_members m on m.collection_id = c.id
            where c.deleted_at is null and m.user_id = ?
            order by c.created_at asc
            """
            do {
                let stream = try database.watch(
                    sql: sql,
                    parameters: [userID],
                    mapper: { VinylCollection.from(cursor: $0) }
                )
                for try await rows in stream {
                    let mapped = rows.compactMap { $0 }
                    Log.event("collections watch emitted", category: "collections.watch", metadata: ["count": mapped.count])
                    await MainActor.run { self.collections = mapped }
                }
            } catch {
                Log.error(error, category: "collections.watch")
            }
        }
    }

    private func watchMembers(userID: String) {
        membersTask?.cancel()
        membersTask = Task { [weak self, database] in
            guard let self else { return }
            let sql = """
            select * from collection_members
            where collection_id in (
              select collection_id from collection_members where user_id = ?
            )
            """
            do {
                let stream = try database.watch(
                    sql: sql,
                    parameters: [userID],
                    mapper: { CollectionMember.from(cursor: $0) }
                )
                for try await rows in stream {
                    let mapped = rows.compactMap { $0 }
                    Log.event("collection members watch emitted", category: "collections.members.watch", metadata: ["count": mapped.count])
                    await MainActor.run { self.members = mapped }
                    let collectionIDs = Set(mapped.map(\.collectionID))
                    for collectionID in collectionIDs where !self.refreshedProfileCollectionIDs.contains(collectionID) {
                        await self.refreshMemberProfiles(collectionID: collectionID)
                    }
                }
            } catch {
                Log.error(error, category: "collections.members.watch")
            }
        }
    }

    private func watchPendingInvites(userID: String) {
        invitesTask?.cancel()
        invitesTask = Task { [weak self, database] in
            guard let self else { return }
            let sql = """
            select * from collection_pending_invites
            where collection_id in (
              select collection_id from collection_members where user_id = ?
            )
            and accepted_at is null
            order by created_at desc
            """
            do {
                let stream = try database.watch(
                    sql: sql,
                    parameters: [userID],
                    mapper: { CollectionPendingInvite.from(cursor: $0) }
                )
                for try await rows in stream {
                    let mapped = rows.compactMap { $0 }
                    Log.event("collection invites watch emitted", category: "collections.invites.watch", metadata: ["count": mapped.count])
                    await MainActor.run { self.pendingInvites = mapped }
                }
            } catch {
                Log.error(error, category: "collections.invites.watch")
            }
        }
    }

    /// Create a new shared Collection and add the creator as the owner.
    /// Membership creation goes via REST because `collection_members` syncs
    /// read-only (composite PK + synthetic `id`).
    func create(name: String) async -> VinylCollection? {
        Log.breadcrumb("collection create started", category: "collections.create")
        guard let createdBy = auth.currentUserID?.lowerUUID else { return nil }
        let id = UUID().lowerUUID
        let now = Date()
        let nowString = now.iso8601
        do {
            try await database.execute(
                sql: """
                insert into collections (id, name, created_by, created_at, updated_at)
                values (?, ?, ?, ?, ?)
                """,
                parameters: [id, name, createdBy, nowString, nowString]
            )
            // The owner row in collection_members must come from the server
            // (RLS lets the creator insert when they own the collection).
            try await auth.supabase
                .from("collection_members")
                .insert([
                    "collection_id": id,
                    "user_id": createdBy,
                    "role": "owner",
                    "invited_by": createdBy,
                ])
                .execute()
            Log.event("collection create completed", category: "collections.create", metadata: ["collectionID": id])
            return VinylCollection(
                id: id, name: name, createdBy: createdBy,
                createdAt: now, updatedAt: now, deletedAt: nil
            )
        } catch {
            Log.error(error, category: "collections.create")
            return nil
        }
    }

    func rename(collectionID: String, name: String) async {
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: "update collections set name = ?, updated_at = ? where id = ?",
                parameters: [name, now, collectionID]
            )
        } catch {
            Log.error(error, category: "collections.rename")
        }
    }

    /// Soft-delete. Only allowed for owner-role members (RLS enforces).
    func softDelete(collectionID: String) async {
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: "update collections set deleted_at = ?, updated_at = ? where id = ?",
                parameters: [now, now, collectionID]
            )
        } catch {
            Log.error(error, category: "collections.softDelete")
        }
    }

    enum InviteOutcome: Equatable {
        case added       // Email matched an existing user; they're now in collection_members.
        case pending     // No account yet; stored in collection_pending_invites and resolved on signup.
    }

    func invite(collectionID: String, email: String, role: CollectionMemberRole) async throws -> InviteOutcome {
        Log.event("collection invite started", category: "collections.invite", metadata: [
            "collectionID": collectionID,
            "role": role.rawValue,
        ])
        struct InviteResult: Decodable { let status: String }
        let result: InviteResult = try await auth.supabase
            .rpc("invite_to_collection", params: [
                "p_collection_id": collectionID,
                "p_email": email,
                "p_role": role.rawValue,
            ])
            .execute()
            .value
        Log.event("collection invite completed", category: "collections.invite", metadata: [
            "collectionID": collectionID,
            "status": result.status,
        ])
        switch result.status {
        case "added":   return .added
        case "pending": return .pending
        default:
            throw NSError(domain: "deadwaxclub.collections", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Unexpected invite response: \(result.status)"
            ])
        }
    }

    func removeMember(collectionID: String, userID: String) async {
        do {
            try await auth.supabase
                .from("collection_members")
                .delete()
                .eq("collection_id", value: collectionID)
                .eq("user_id", value: userID)
                .execute()
        } catch {
            Log.error(error, category: "collections.removeMember")
        }
    }

    func refreshMemberProfiles(collectionID: String) async {
        do {
            let profiles: [CollectionMemberProfile] = try await auth.supabase
                .rpc("get_collection_member_profiles", params: ["p_collection_id": collectionID])
                .execute()
                .value
            var updated = memberProfilesByID
            for profile in profiles {
                updated[profile.id] = profile
            }
            memberProfilesByID = updated
            refreshedProfileCollectionIDs.insert(collectionID)
        } catch {
            Log.error(error, category: "collections.memberProfiles")
        }
    }

    func leave(collectionID: String) async {
        guard let userID = auth.currentUserID?.lowerUUID else { return }
        await removeMember(collectionID: collectionID, userID: userID)
    }

    func revokePendingInvite(inviteID: String) async {
        do {
            _ = try await auth.supabase
                .rpc("revoke_collection_invite", params: ["p_invite_id": inviteID])
                .execute()
        } catch {
            Log.error(error, category: "collections.revokePendingInvite")
        }
    }

    /// Updates the user's `primary_collection_id` so new records land here by default.
    func setPrimary(collectionID: String) async {
        guard let userID = auth.currentUserID?.lowerUUID else { return }
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: "update profiles set primary_collection_id = ?, updated_at = ? where id = ?",
                parameters: [collectionID, now, userID]
            )
        } catch {
            Log.error(error, category: "collections.setPrimary")
        }
    }

    /// Move every record (and its price entries) currently in `from` into `to`.
    /// Used by the "Move all my records" affordance when a user joins a shared
    /// Collection and wants to consolidate from their personal one.
    func moveAllRecords(from sourceCollectionID: String, to destinationCollectionID: String) async {
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: """
                update records set collection_id = ?, updated_at = ?
                where collection_id = ? and deleted_at is null
                """,
                parameters: [destinationCollectionID, now, sourceCollectionID]
            )
            try await database.execute(
                sql: """
                update price_entries set collection_id = ?
                where collection_id = ?
                """,
                parameters: [destinationCollectionID, sourceCollectionID]
            )
        } catch {
            Log.error(error, category: "collections.moveAllRecords")
        }
    }
}
