import Combine
import Foundation
import PowerSync

/// Watches every Collection the user belongs to. Writes to `collections` flow
/// through PowerSync's CRUD queue. Membership and invites live in the shared
/// sharing core (`sharing`), which changes them through the Deadwax API
/// (`api/library/...`) because `collection_members` is read-only locally
/// (composite PK + computed `id`).
@MainActor
final class CollectionsRepository: ObservableObject {
    @Published private(set) var collections: [VinylCollection] = []

    let sharing: SharingRepository
    /// Collection invites sent to this account.
    let inbox: SharingInbox

    private let database: PowerSyncDatabaseProtocol
    private let auth: AuthClient
    private var collectionsTask: Task<Void, Never>?
    private var sharingChanges: AnyCancellable?

    init(database: PowerSyncDatabaseProtocol, auth: AuthClient, owner: UUID? = nil) {
        self.database = database
        self.auth = auth
        self.sharing = SharingRepository(space: .collection, database: database, auth: auth, owner: owner)
        self.inbox = SharingInbox([sharing])
        sharingChanges = sharing.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    deinit {
        collectionsTask?.cancel()
    }

    func startWatching(userID: String) {
        Log.breadcrumb("collections watch starting", category: "collections.watch")
        watchCollections(userID: userID)
        sharing.startWatching(userID: userID)
    }

    func stopWatching() {
        Log.breadcrumb("collections watch stopping", category: "collections.watch")
        collectionsTask?.cancel(); collectionsTask = nil
        collections = []
        sharing.stopWatching()
    }

    func members(of collectionID: String) -> [ShareMember] {
        sharing.members(of: collectionID)
    }

    func role(in collectionID: String, userID: String) -> ShareRole? {
        sharing.role(in: collectionID, userID: userID)
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
                    guard !Task.isCancelled else { return }
                    let mapped = rows.compactMap { $0 }
                    Log.event("collections watch emitted", category: "collections.watch", metadata: ["count": mapped.count])
                    await MainActor.run { self.collections = mapped }
                }
            } catch {
                Log.error(error, category: "collections.watch")
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
