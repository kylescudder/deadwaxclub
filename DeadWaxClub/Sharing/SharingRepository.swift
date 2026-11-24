import Foundation
import PowerSync

/// Members and pending invites of every space of one `SharingSpace` kind the
/// signed-in account belongs to. Both tables sync read-only, so reads come
/// from the local database and every change goes through the space's API
/// endpoints, sent with the owner's token. PowerSync then syncs the result.
@MainActor
final class SharingRepository: ObservableObject {
    @Published private(set) var members: [ShareMember] = []
    @Published private(set) var pendingInvites: [SharePendingInvite] = []
    @Published private(set) var memberProfilesByID: [String: ShareMemberProfile] = [:]

    let space: SharingSpace

    private let database: PowerSyncDatabaseProtocol
    private let auth: AuthClient
    private let owner: UUID?
    private var membersTask: Task<Void, Never>?
    private var invitesTask: Task<Void, Never>?
    private var refreshedProfileSpaceIDs: Set<String> = []

    init(space: SharingSpace, database: PowerSyncDatabaseProtocol, auth: AuthClient, owner: UUID? = nil) {
        self.space = space
        self.database = database
        self.auth = auth
        self.owner = owner ?? auth.currentUserID
    }

    deinit {
        membersTask?.cancel()
        invitesTask?.cancel()
    }

    // MARK: Reading

    func startWatching(userID: String) {
        Log.breadcrumb("\(space.name) sharing watch starting", category: category("watch"))
        watchMembers(userID: userID)
        watchPendingInvites(userID: userID)
    }

    func stopWatching() {
        membersTask?.cancel(); membersTask = nil
        invitesTask?.cancel(); invitesTask = nil
        members = []
        pendingInvites = []
        memberProfilesByID = [:]
        refreshedProfileSpaceIDs = []
    }

    func members(of spaceID: String) -> [ShareMember] {
        members.filter { $0.spaceID == spaceID }
    }

    /// Every space `userID` belongs to, with their role in it.
    func memberships(of userID: String) -> [ShareMember] {
        members.filter { $0.userID == userID }
    }

    func pendingInvites(for spaceID: String) -> [SharePendingInvite] {
        pendingInvites.filter { $0.spaceID == spaceID }
    }

    func role(in spaceID: String, userID: String) -> ShareRole? {
        members.first { $0.spaceID == spaceID && $0.userID == userID }?.role
    }

    /// The space is shared with at least one person besides its owner, or has an open invite.
    func isShared(_ spaceID: String) -> Bool {
        members(of: spaceID).contains { $0.role != .owner } || !pendingInvites(for: spaceID).isEmpty
    }

    func displayName(for userID: String) -> String? {
        let trimmed = memberProfilesByID[userID]?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    static func membersSQL(for space: SharingSpace) -> String {
        """
        select * from \(space.membersTable)
        where \(space.spaceColumn) in (
          select \(space.spaceColumn) from \(space.membersTable) where user_id = ?
        )
        order by joined_at asc
        """
    }

    static func invitesSQL(for space: SharingSpace) -> String {
        """
        select * from \(space.invitesTable)
        where \(space.spaceColumn) in (
          select \(space.spaceColumn) from \(space.membersTable) where user_id = ?
        )
        and accepted_at is null
        order by created_at desc
        """
    }

    private func watchMembers(userID: String) {
        membersTask?.cancel()
        let space = space
        membersTask = Task { [weak self, database] in
            do {
                let stream = try database.watch(
                    sql: Self.membersSQL(for: space),
                    parameters: [userID],
                    mapper: { ShareMember.from(cursor: $0, spaceColumn: space.spaceColumn) }
                )
                for try await rows in stream {
                    guard !Task.isCancelled, let self else { return }
                    let mapped = rows.compactMap { $0 }
                    Log.event("\(space.name) members watch emitted", category: self.category("watch"), metadata: ["count": mapped.count])
                    self.members = mapped
                    for spaceID in Set(mapped.map(\.spaceID)) where !self.refreshedProfileSpaceIDs.contains(spaceID) {
                        await self.refreshMemberProfiles(spaceID: spaceID)
                    }
                }
            } catch {
                Log.error(error, category: "sharing.\(space.name).watch")
            }
        }
    }

    private func watchPendingInvites(userID: String) {
        invitesTask?.cancel()
        let space = space
        invitesTask = Task { [weak self, database] in
            do {
                let stream = try database.watch(
                    sql: Self.invitesSQL(for: space),
                    parameters: [userID],
                    mapper: { SharePendingInvite.from(cursor: $0, spaceColumn: space.spaceColumn) }
                )
                for try await rows in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.pendingInvites = rows.compactMap { $0 }
                }
            } catch {
                Log.error(error, category: "sharing.\(space.name).invites")
            }
        }
    }

    // MARK: Changing membership

    func invite(spaceID: String, email: String, role: ShareRole) async throws -> ShareInviteOutcome {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), !email.hasPrefix("@"), !email.hasSuffix("@") else { throw SharingError.invalidEmail }
        Log.event("\(space.name) invite started", category: category("invite"), metadata: ["role": role.rawValue])
        let data = try await send(space.invite, [spaceID, email, role.rawValue])
        struct InviteResult: Decodable { let status: String }
        let result = try JSONDecoder().decode(InviteResult.self, from: data)
        Log.event("\(space.name) invite completed", category: category("invite"), metadata: ["status": result.status])
        switch result.status {
        case "added": return .added
        case "pending": return .pending
        default: throw SharingError.unexpectedResponse(result.status)
        }
    }

    @discardableResult
    func removeMember(spaceID: String, userID: String) async -> Bool {
        do {
            _ = try await send(space.removeMember, [spaceID, userID])
            return true
        } catch {
            Log.error(error, category: category("removeMember"))
            return false
        }
    }

    /// Removes the signed-in account from a space it doesn't own.
    @discardableResult
    func leave(spaceID: String) async -> Bool {
        guard let userID = auth.currentUserID?.uuidString.lowercased() else { return false }
        return await removeMember(spaceID: spaceID, userID: userID)
    }

    @discardableResult
    func revokePendingInvite(inviteID: String) async -> Bool {
        do {
            _ = try await send(space.revokeInvite, [inviteID])
            return true
        } catch {
            Log.error(error, category: category("revokeInvite"))
            return false
        }
    }

    func refreshMemberProfiles(spaceID: String) async {
        do {
            let data = try await send(space.memberProfiles, [spaceID])
            let profiles = try JSONDecoder().decode([ShareMemberProfile].self, from: data)
            guard auth.currentUserID == owner, !Task.isCancelled else { return }
            var updated = memberProfilesByID
            for profile in profiles {
                updated[profile.id] = profile
            }
            memberProfilesByID = updated
            refreshedProfileSpaceIDs.insert(spaceID)
        } catch {
            Log.error(error, category: category("memberProfiles"))
        }
    }

    private func send(_ endpoint: SharingEndpoint, _ values: [String]) async throws -> Data {
        guard let owner, let token = await auth.currentAccessToken(for: owner) else { throw SharingError.signedOut }
        return try await auth.api.json(endpoint.path, values: endpoint.body(values), expectedToken: token)
    }

    private func category(_ action: String) -> String { "sharing.\(space.name).\(action)" }
}
