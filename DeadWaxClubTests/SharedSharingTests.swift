import Foundation
import PowerSync
import XCTest
@testable import AppUnderTest

/// Behaviour of the shared sharing core for every space the app declares in
/// `SharingAppConfiguration.spaces`: which memberships are visible, roles,
/// and the requests sent to the sharing endpoints.
@MainActor
final class SharedSharingTests: XCTestCase {
    private var databases: [PowerSyncDatabaseProtocol] = []

    override func tearDown() async throws {
        for database in databases {
            try? await database.close(deleteDatabase: true)
        }
        databases = []
        SharingStubProtocol.handler = nil
        try await super.tearDown()
    }

    // MARK: Configuration

    func testEverySpaceSyncsReadOnlyTables() {
        XCTAssertFalse(SharingAppConfiguration.spaces.isEmpty)
        let synced = Set(DatabaseSchema.schema.tables.filter { !$0.localOnly }.map(\.name))
        for space in SharingAppConfiguration.spaces {
            XCTAssertTrue(synced.contains(space.membersTable), space.membersTable)
            XCTAssertTrue(synced.contains(space.invitesTable), space.invitesTable)
            XCTAssertFalse(SyncAppConfiguration.writableTables.contains(space.membersTable), space.membersTable)
            XCTAssertFalse(SyncAppConfiguration.writableTables.contains(space.invitesTable), space.invitesTable)
        }
        XCTAssertEqual(Set(SharingAppConfiguration.spaces.map(\.name)).count, SharingAppConfiguration.spaces.count)
    }

    func testEveryEndpointTakesTheValuesTheRepositorySends() {
        for space in SharingAppConfiguration.spaces {
            XCTAssertEqual(space.invite.keys.count, 3, space.invite.path)
            XCTAssertEqual(space.removeMember.keys.count, 2, space.removeMember.path)
            XCTAssertEqual(space.revokeInvite.keys.count, 1, space.revokeInvite.path)
            XCTAssertEqual(space.memberProfiles.keys.count, 1, space.memberProfiles.path)
            XCTAssertEqual(space.incoming.keys.count, 0, space.incoming.path)
            XCTAssertEqual(space.accept.keys.count, 1, space.accept.path)
            XCTAssertEqual(space.decline.keys.count, 1, space.decline.path)
            for endpoint in [space.invite, space.removeMember, space.revokeInvite, space.memberProfiles, space.incoming, space.accept, space.decline] {
                XCTAssertFalse(endpoint.path.hasPrefix("/"), endpoint.path)
                XCTAssertEqual(Set(endpoint.keys).count, endpoint.keys.count, endpoint.path)
            }
        }
    }

    func testRolesRankAndOnlyEditorsAndViewersAreInvitable() {
        XCTAssertLessThan(ShareRole.viewer, .editor)
        XCTAssertLessThan(ShareRole.editor, .owner)
        XCTAssertEqual([ShareRole.viewer, .owner, .editor].max(), .owner)
        XCTAssertFalse(ShareRole.viewer.canEdit)
        XCTAssertTrue(ShareRole.editor.canEdit)
        XCTAssertTrue(ShareRole.owner.canEdit)
        XCTAssertEqual(ShareRole.invitable, [.editor, .viewer])
    }

    func testSyncedTimestampsParse() {
        XCTAssertNotNil(sharingDate("2026-11-23T10:15:00Z"))
        XCTAssertNotNil(sharingDate("2026-11-23T10:15:00.123Z"))
        XCTAssertNotNil(sharingDate("2026-11-23 10:15:00.123456Z"))
        XCTAssertNil(sharingDate(""))
        XCTAssertNil(sharingDate(nil))
    }

    // MARK: Reading

    func testOnlySpacesTheAccountBelongsToAreVisible() async throws {
        let (auth, me) = try await makeSignedInAuth()
        SharingStubProtocol.handler = { _ in (200, Data("[]".utf8)) }
        let userID = me.uuidString.lowercased()
        let other = UUID().uuidString.lowercased()
        let stranger = UUID().uuidString.lowercased()
        for space in SharingAppConfiguration.spaces {
            let database = makeDatabase()
            let owned = UUID().uuidString.lowercased()
            let joined = UUID().uuidString.lowercased()
            let unrelated = UUID().uuidString.lowercased()
            try await insertMember(database, space, spaceID: owned, userID: userID, role: .owner)
            try await insertMember(database, space, spaceID: owned, userID: other, role: .editor)
            try await insertMember(database, space, spaceID: joined, userID: other, role: .owner)
            try await insertMember(database, space, spaceID: joined, userID: userID, role: .viewer)
            try await insertMember(database, space, spaceID: unrelated, userID: stranger, role: .owner)
            try await insertInvite(database, space, spaceID: owned, email: "open@example.test")
            try await insertInvite(database, space, spaceID: owned, email: "done@example.test", accepted: true)
            try await insertInvite(database, space, spaceID: unrelated, email: "hidden@example.test")

            let sharing = SharingRepository(space: space, database: database, auth: auth)
            sharing.startWatching(userID: userID)
            try await waitUntil { sharing.members.count == 4 && sharing.pendingInvites.count == 1 }

            XCTAssertEqual(Set(sharing.members.map(\.spaceID)), [owned, joined], space.name)
            XCTAssertEqual(sharing.role(in: owned, userID: userID), .owner)
            XCTAssertEqual(sharing.role(in: joined, userID: userID), .viewer)
            XCTAssertNil(sharing.role(in: unrelated, userID: userID))
            XCTAssertEqual(Set(sharing.memberships(of: userID).map(\.spaceID)), [owned, joined])
            XCTAssertEqual(sharing.pendingInvites(for: owned).map(\.email), ["open@example.test"])
            XCTAssertTrue(sharing.isShared(owned))
            XCTAssertTrue(sharing.isShared(joined))

            sharing.stopWatching()
            XCTAssertTrue(sharing.members.isEmpty)
            XCTAssertTrue(sharing.pendingInvites.isEmpty)
        }
    }

    func testMemberProfilesNameMembers() async throws {
        let (auth, me) = try await makeSignedInAuth()
        let userID = me.uuidString.lowercased()
        SharingStubProtocol.handler = { _ in
            (200, Data(#"[{"id":"\#(userID)","display_name":"  Sam  "},{"id":"x","display_name":" "}]"#.utf8))
        }
        let space = try XCTUnwrap(SharingAppConfiguration.spaces.first)
        let sharing = SharingRepository(space: space, database: makeDatabase(), auth: auth)

        await sharing.refreshMemberProfiles(spaceID: UUID().uuidString.lowercased())

        XCTAssertEqual(sharing.displayName(for: userID), "Sam")
        XCTAssertNil(sharing.displayName(for: "x"))
        XCTAssertNil(sharing.displayName(for: "missing"))
    }

    // MARK: Changing membership

    func testInviteSendsTheSpaceEmailAndRoleWithTheOwnersToken() async throws {
        let (auth, _) = try await makeSignedInAuth(token: "owner-token")
        let requests = SharingRequestLog()
        for space in SharingAppConfiguration.spaces {
            for (status, outcome) in [("added", ShareInviteOutcome.added), ("pending", .pending)] {
                SharingStubProtocol.handler = { request in
                    requests.append(request)
                    return (200, Data(#"{"status":"\#(status)"}"#.utf8))
                }
                let spaceID = UUID().uuidString.lowercased()
                let sharing = SharingRepository(space: space, database: makeDatabase(), auth: auth)

                let result = try await sharing.invite(spaceID: spaceID, email: "  Friend@Example.TEST ", role: .viewer)

                XCTAssertEqual(result, outcome)
                let sent = try XCTUnwrap(requests.values.last)
                XCTAssertEqual(sent.path, "/" + space.invite.path)
                XCTAssertEqual(sent.authorization, "Bearer owner-token")
                XCTAssertEqual(sent.body[space.invite.keys[0]] as? String, spaceID)
                XCTAssertEqual(sent.body[space.invite.keys[1]] as? String, "friend@example.test")
                XCTAssertEqual(sent.body[space.invite.keys[2]] as? String, "viewer")
            }
        }
    }

    func testInviteRejectsUnknownStatusesAndInvalidEmails() async throws {
        let (auth, _) = try await makeSignedInAuth()
        let requests = SharingRequestLog()
        SharingStubProtocol.handler = { request in
            requests.append(request)
            return (200, Data(#"{"status":"surprise"}"#.utf8))
        }
        let space = try XCTUnwrap(SharingAppConfiguration.spaces.first)
        let sharing = SharingRepository(space: space, database: makeDatabase(), auth: auth)

        do {
            _ = try await sharing.invite(spaceID: "s", email: "friend@example.test", role: .editor)
            XCTFail("Expected an unexpected-response error")
        } catch {
            XCTAssertEqual(error as? SharingError, .unexpectedResponse("surprise"))
        }
        for email in ["", "friend", "@example.test", "friend@"] {
            do {
                _ = try await sharing.invite(spaceID: "s", email: email, role: .editor)
                XCTFail("Expected \(email) to be rejected")
            } catch {
                XCTAssertEqual(error as? SharingError, .invalidEmail)
            }
        }
        XCTAssertEqual(requests.values.count, 1)
    }

    func testRemovingLeavingAndRevokingSendTheirIDs() async throws {
        let (auth, me) = try await makeSignedInAuth()
        let requests = SharingRequestLog()
        SharingStubProtocol.handler = { request in
            requests.append(request)
            return (200, Data("null".utf8))
        }
        for space in SharingAppConfiguration.spaces {
            let sharing = SharingRepository(space: space, database: makeDatabase(), auth: auth)

            let removed = await sharing.removeMember(spaceID: "space-1", userID: "user-1")
            let left = await sharing.leave(spaceID: "space-2")
            let revoked = await sharing.revokePendingInvite(inviteID: "invite-1")

            XCTAssertTrue(removed && left && revoked)
            let sent = requests.values.suffix(3)
            XCTAssertEqual(sent.map(\.path), ["/" + space.removeMember.path, "/" + space.removeMember.path, "/" + space.revokeInvite.path])
            let bodies = sent.map(\.body)
            XCTAssertEqual(bodies[bodies.startIndex][space.removeMember.keys[0]] as? String, "space-1")
            XCTAssertEqual(bodies[bodies.startIndex][space.removeMember.keys[1]] as? String, "user-1")
            XCTAssertEqual(bodies[bodies.startIndex + 1][space.removeMember.keys[1]] as? String, me.uuidString.lowercased())
            XCTAssertEqual(bodies[bodies.startIndex + 2][space.revokeInvite.keys[0]] as? String, "invite-1")
        }
    }

    func testFailedChangesReportFailure() async throws {
        let (auth, _) = try await makeSignedInAuth()
        SharingStubProtocol.handler = { _ in (403, Data(#"{"code":"forbidden","message":"No."}"#.utf8)) }
        let space = try XCTUnwrap(SharingAppConfiguration.spaces.first)
        let sharing = SharingRepository(space: space, database: makeDatabase(), auth: auth)

        let removed = await sharing.removeMember(spaceID: "s", userID: "u")
        let revoked = await sharing.revokePendingInvite(inviteID: "i")

        XCTAssertFalse(removed)
        XCTAssertFalse(revoked)
        do {
            _ = try await sharing.invite(spaceID: "s", email: "friend@example.test", role: .editor)
            XCTFail("Expected the server's refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No.")
        }
    }

    func testSignedOutChangesSendNothing() async throws {
        let auth = try makeAuth()
        await auth.bootstrap(offlineAccount: { ([], false) })
        let requests = SharingRequestLog()
        SharingStubProtocol.handler = { request in
            requests.append(request)
            return (200, Data(#"{"status":"added"}"#.utf8))
        }
        let space = try XCTUnwrap(SharingAppConfiguration.spaces.first)
        let sharing = SharingRepository(space: space, database: makeDatabase(), auth: auth)

        do {
            _ = try await sharing.invite(spaceID: "s", email: "friend@example.test", role: .editor)
            XCTFail("Expected a signed-out error")
        } catch {
            XCTAssertEqual(error as? SharingError, .signedOut)
        }
        let left = await sharing.leave(spaceID: "s")
        XCTAssertFalse(left)
        XCTAssertTrue(requests.values.isEmpty)
    }

    // MARK: Answering invites

    func testIncomingInvitesAreFetchedAndAnsweredWithTheirIDs() async throws {
        let (auth, _) = try await makeSignedInAuth(token: "invitee-token")
        let requests = SharingRequestLog()
        for space in SharingAppConfiguration.spaces {
            SharingStubProtocol.handler = { request in
                requests.append(request)
                if request.path == "/" + space.incoming.path {
                    return (200, Data(#"[{"id":"i1","space_id":"s1","space_name":"Lisbon","inviter_name":"Sam","role":"viewer","created_at":"2026-11-24T10:00:00.000Z"},{"id":"i2","space_id":"s2","space_name":null,"inviter_name":null,"role":"editor","created_at":"2026-11-24T11:00:00.000Z"}]"#.utf8))
                }
                return (200, Data(#"{"status":"accepted","space_id":"s1"}"#.utf8))
            }
            let sharing = SharingRepository(space: space, database: makeDatabase(), auth: auth)

            await sharing.refreshIncomingInvites()

            XCTAssertEqual(sharing.incomingInvites.map(\.id), ["i1", "i2"], space.name)
            let first = try XCTUnwrap(sharing.incomingInvites.first)
            XCTAssertEqual(first.spaceName, "Lisbon")
            XCTAssertEqual(first.inviterName, "Sam")
            XCTAssertEqual(first.role, .viewer)
            XCTAssertNotNil(first.createdAt)
            XCTAssertNil(sharing.incomingInvites[1].spaceName)

            try await sharing.accept(first)
            let accepted = try XCTUnwrap(requests.values.last)
            XCTAssertEqual(accepted.path, "/" + space.accept.path)
            XCTAssertEqual(accepted.authorization, "Bearer invitee-token")
            XCTAssertEqual(accepted.body[space.accept.keys[0]] as? String, "i1")

            try await sharing.decline(sharing.incomingInvites[0])
            let declined = try XCTUnwrap(requests.values.last)
            XCTAssertEqual(declined.path, "/" + space.decline.path)
            XCTAssertEqual(declined.body[space.decline.keys[0]] as? String, "i2")
            XCTAssertTrue(sharing.incomingInvites.isEmpty)
        }
    }

    func testARefusedAnswerKeepsTheInviteAndExplainsWhy() async throws {
        let (auth, _) = try await makeSignedInAuth()
        let space = try XCTUnwrap(SharingAppConfiguration.spaces.first)
        SharingStubProtocol.handler = { request in
            if request.path == "/" + space.incoming.path {
                return (200, Data(#"[{"id":"i1","space_id":"s1","role":"editor"}]"#.utf8))
            }
            return (422, Data(#"{"code":"invalid","message":"This invite is no longer available."}"#.utf8))
        }
        let sharing = SharingRepository(space: space, database: makeDatabase(), auth: auth)
        await sharing.refreshIncomingInvites()
        let invite = try XCTUnwrap(sharing.incomingInvites.first)

        do {
            try await sharing.accept(invite)
            XCTFail("Expected the server's refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This invite is no longer available.")
        }
        XCTAssertEqual(sharing.incomingInvites, [invite])
    }

    func testTheInboxListsEverySpacesInvitesNewestFirstAndAnswersThroughTheRightSpace() async throws {
        let (auth, _) = try await makeSignedInAuth()
        let requests = SharingRequestLog()
        let spaces = SharingAppConfiguration.spaces
        SharingStubProtocol.handler = { request in
            requests.append(request)
            for (index, space) in spaces.enumerated() where request.path == "/" + space.incoming.path {
                return (200, Data(#"[{"id":"\#(space.name)","space_id":"s","role":"editor","created_at":"2026-11-2\#(index)T10:00:00Z"}]"#.utf8))
            }
            return (200, Data("null".utf8))
        }
        let repositories = spaces.map { SharingRepository(space: $0, database: makeDatabase(), auth: auth) }
        let inbox = SharingInbox(repositories)

        await inbox.refresh()

        XCTAssertEqual(inbox.entries.map(\.invite.id), spaces.reversed().map(\.name))
        let oldest = try XCTUnwrap(inbox.entries.last)
        try await inbox.accept(oldest)
        XCTAssertEqual(requests.values.last?.path, "/" + oldest.space.accept.path)
        XCTAssertEqual(inbox.entries.count, spaces.count - 1)
        for repository in repositories { repository.stopWatching() }
        XCTAssertTrue(inbox.entries.isEmpty)
    }

    // MARK: Helpers

    private func makeDatabase() -> PowerSyncDatabaseProtocol {
        let database = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: "shared-sharing-\(UUID().uuidString).sqlite")
        databases.append(database)
        return database
    }

    private func insertMember(_ database: PowerSyncDatabaseProtocol, _ space: SharingSpace, spaceID: String, userID: String, role: ShareRole) async throws {
        try await database.execute(
            sql: "insert into \(space.membersTable) (id, \(space.spaceColumn), user_id, role, joined_at) values (?, ?, ?, ?, ?)",
            parameters: ["\(spaceID):\(userID)", spaceID, userID, role.rawValue, "2026-11-23T10:00:00Z"]
        )
    }

    private func insertInvite(_ database: PowerSyncDatabaseProtocol, _ space: SharingSpace, spaceID: String, email: String, accepted: Bool = false) async throws {
        try await database.execute(
            sql: "insert into \(space.invitesTable) (id, \(space.spaceColumn), email, role, invited_by, created_at, accepted_at) values (?, ?, ?, 'editor', ?, ?, ?)",
            parameters: [UUID().uuidString.lowercased(), spaceID, email, UUID().uuidString.lowercased(), "2026-11-23T10:00:00Z", accepted ? "2026-11-23T11:00:00Z" : nil]
        )
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the watch")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeAuth(store: SharingMemorySessionStore = SharingMemorySessionStore(), api: APIClient? = nil) throws -> AuthClient {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharingStubProtocol.self]
        let client = api ?? APIClient(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://sharing.example.test")!,
            configurationError: nil
        )
        return AuthClient(sessionStore: store, defaults: defaults, api: client)
    }

    private func makeSignedInAuth(token: String = "session-token") async throws -> (AuthClient, UUID) {
        let owner = UUID()
        let store = SharingMemorySessionStore()
        store.data = try JSONSerialization.data(withJSONObject: [
            "token": token,
            "user": ["id": owner.uuidString, "email": "sharing@example.test"],
        ])
        let auth = try makeAuth(store: store)
        await auth.bootstrap(offlineAccount: { ([owner], false) })
        XCTAssertEqual(auth.currentUserID, owner)
        return (auth, owner)
    }
}

private struct SharingRecordedRequest: Sendable {
    let path: String
    let authorization: String?
    let bodyData: Data

    var body: [String: Any] {
        (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
    }
}

private final class SharingRequestLog: @unchecked Sendable {
    // Guarded by `lock`; URLProtocol callbacks arrive off the main actor.
    private let lock = NSLock()
    private var stored: [SharingRecordedRequest] = []

    var values: [SharingRecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func append(_ request: SharingRecordedRequest) {
        lock.lock(); defer { lock.unlock() }
        stored.append(request)
    }
}

private final class SharingStubProtocol: URLProtocol, @unchecked Sendable {
    // Guarded by `lock`; URLProtocol callbacks arrive off the main actor.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: (@Sendable (SharingRecordedRequest) -> (Int, Data))?
    static var handler: (@Sendable (SharingRecordedRequest) -> (Int, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let recorded = SharingRecordedRequest(
            path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            bodyData: request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        )
        let (status, data) = Self.handler?(recorded) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@MainActor
private final class SharingMemorySessionStore: SessionStore {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data?) throws { self.data = data }
}
