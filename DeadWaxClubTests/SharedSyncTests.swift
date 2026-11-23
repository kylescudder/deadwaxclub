import Foundation
import PowerSync
import XCTest
#if canImport(Diald)
@testable import Diald
#else
@testable import DeadWaxClub
#endif

/// Behaviour of the shared sync core: offline ownership, the auth-driven
/// connection lifecycle, and which upload failures are acknowledged versus
/// kept queued for retry.
@MainActor
final class SharedSyncTests: XCTestCase {
    private var databases: [PowerSyncDatabaseProtocol] = []

    override func tearDown() async throws {
        for database in databases {
            try? await database.close(deleteDatabase: true)
        }
        databases = []
        SyncStubProtocol.handler = nil
        try await super.tearDown()
    }

    // MARK: Connection lifecycle

    func testAuthStateDrivesConnectionWithoutClearing() {
        XCTAssertEqual(PowerSyncManager.action(for: .unknown), .none)
        XCTAssertEqual(PowerSyncManager.action(for: .signedOut), .disconnect)
        XCTAssertEqual(PowerSyncManager.action(for: .signedIn(userID: UUID(), email: nil)), .connect)
        XCTAssertEqual(
            PowerSyncManager.action(for: .signedIn(userID: UUID(), email: nil), requiresReauthentication: true),
            .disconnect
        )
        XCTAssertEqual(PowerSyncManager.action(for: .unknown, requiresReauthentication: true), .disconnect)
    }

    // MARK: Offline ownership

    func testOfflineOwnerKeepsTheAccountAndItsQueue() async throws {
        let database = makeDatabase()
        let owner = UUID()
        try await database.execute(sql: "insert into profiles (id) values (?)", parameters: [owner.uuidString.lowercased()])
        let before = try await crudData(database)
        let auth = try makeAuth()
        let manager = PowerSyncManager(auth: auth, issues: SyncIssueStore(), database: database)

        await auth.bootstrap(offlineAccount: manager.offlineAccount)

        XCTAssertNil(auth.currentUserID)
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertFalse(auth.requiresReauthentication)
        let token = await auth.currentAccessToken()
        XCTAssertNil(token)
        let after = try await crudData(database)
        XCTAssertFalse(before.isEmpty)
        XCTAssertEqual(after, before)
    }

    func testAmbiguousOfflineOwnersCannotExposeCachedDataOrUpload() async throws {
        let database = makeDatabase()
        for _ in 0..<2 {
            try await database.execute(sql: "insert into profiles (id) values (?)", parameters: [UUID().uuidString.lowercased()])
        }
        let auth = try makeAuth()
        let manager = PowerSyncManager(auth: auth, issues: SyncIssueStore(), database: database)

        await auth.bootstrap(offlineAccount: manager.offlineAccount)

        XCTAssertEqual(auth.state, AuthAppConfiguration.bootstrapFailureState)
        XCTAssertNotNil(auth.lastError)
        XCTAssertNil(auth.currentUserID)
        let token = await auth.currentAccessToken()
        XCTAssertNil(token)
    }

    func testUnknownQueueOwnerRequiresRecoveryBeforeSignIn() async throws {
        let auth = try makeAuth()
        await auth.bootstrap(offlineAccount: { ([], true) })
        XCTAssertEqual(auth.state, AuthAppConfiguration.bootstrapFailureState)
        XCTAssertNotNil(auth.lastError)
    }

    func testCorruptOwnerIDNeedsRecovery() async throws {
        let database = makeDatabase()
        try await database.execute(sql: "insert into profiles (id) values (?)", parameters: ["not-a-uuid"])
        let manager = PowerSyncManager(auth: try makeAuth(), issues: SyncIssueStore(), database: database)
        do {
            _ = try await manager.offlineAccount()
            XCTFail("Expected owner_mismatch")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, "owner_mismatch")
        }
    }

    func testSwitchingAccountsPreservesSeparateRowsAndPendingQueuesAcrossRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let filename = directory.appendingPathComponent("legacy.sqlite").path
        let first = UUID(), second = UUID()
        let auth = try makeAuth()
        let manager = PowerSyncManager(auth: auth, issues: SyncIssueStore(), databaseFilename: filename)
        await auth.bootstrap(offlineAccount: manager.offlineAccount)

        try await manager.selectAccount(first)
        try await manager.database.execute(sql: "insert into profiles (id, display_name) values (?, ?)", parameters: [first.uuidString.lowercased(), "First offline edit"])
        let firstQueue = try await crudData(manager.database)
        try await manager.releaseAccount()
        try await manager.selectAccount(second)
        let emptyQueue = try await crudData(manager.database)
        XCTAssertTrue(emptyQueue.isEmpty)
        try await manager.database.execute(sql: "insert into profiles (id, display_name) values (?, ?)", parameters: [second.uuidString.lowercased(), "Second offline edit"])
        let secondQueue = try await crudData(manager.database)
        try await manager.releaseAccount()

        let relaunched = PowerSyncManager(auth: auth, issues: SyncIssueStore(), databaseFilename: filename)
        try await relaunched.selectAccount(first)
        let names = try await relaunched.database.getAll(sql: "select display_name from profiles", parameters: [], mapper: { try $0.getString(name: "display_name") })
        XCTAssertEqual(names, ["First offline edit"])
        let restoredFirstQueue = try await crudData(relaunched.database)
        XCTAssertEqual(restoredFirstQueue, firstQueue)
        try await relaunched.releaseAccount()
        try await relaunched.selectAccount(second)
        let restoredSecondQueue = try await crudData(relaunched.database)
        XCTAssertEqual(restoredSecondQueue, secondQueue)
        try await relaunched.releaseAccount()
    }

    func testOfflineSignOutSwitchReturnAndUploadUseOnlyTheSelectedAccountsQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncStubProtocol.self]
        let api = APIClient(session: URLSession(configuration: configuration), baseURL: URL(string: "https://sync.example.test")!, configurationError: nil)
        let store = SyncMemorySessionStore()
        let auth = try makeAuth(store: store, api: api)
        let manager = PowerSyncManager(auth: auth, issues: SyncIssueStore(), databaseFilename: directory.appendingPathComponent("legacy.sqlite").path)
        await auth.bootstrap(offlineAccount: manager.offlineAccount)
        let first = UUID(), second = UUID()
        let requests = RequestLog()
        SyncStubProtocol.handler = { request in
            requests.append(request)
            if request.path == "/api/auth/sign-in/email" {
                let id = request.body["email"] as? String == "first@example.test" ? first : second
                let body = try! JSONSerialization.data(withJSONObject: ["token": id.uuidString, "user": ["id": id.uuidString]])
                return (200, body)
            }
            if request.path == "/api/auth/sign-out" { return (0, Data()) } // offline
            return (200, Data(#"{"accepted":true}"#.utf8))
        }
        await auth.signIn(email: "first@example.test", password: "test-password")
        XCTAssertTrue(auth.canAccessMainApp)
        try await manager.database.execute(sql: "insert into profiles (id, display_name) values (?, ?)", parameters: [first.uuidString.lowercased(), "First account offline"])
        let firstQueue = try await crudData(manager.database)
        let oldConnector = APIConnector(auth: auth, issues: SyncIssueStore(), owner: first)
        let signedOut = await auth.signOut()
        XCTAssertTrue(signedOut)
        XCTAssertNil(store.data)
        XCTAssertNil(auth.currentUserID)
        XCTAssertNil(manager.accountID)

        await auth.signIn(email: "second@example.test", password: "test-password")
        XCTAssertEqual(manager.accountID, second)
        let secondInitialQueue = try await crudData(manager.database)
        XCTAssertTrue(secondInitialQueue.isEmpty)
        try await manager.database.execute(sql: "insert into profiles (id, display_name) values (?, ?)", parameters: [second.uuidString.lowercased(), "Second account offline"])
        do {
            try await oldConnector.uploadData(database: manager.database)
            XCTFail("An old connector must not upload using the next account's credentials")
        } catch { XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired) }
        _ = await auth.signOut()
        await auth.signIn(email: "first@example.test", password: "test-password")
        let restored = try await crudData(manager.database)
        XCTAssertEqual(restored, firstQueue)
        try await APIConnector(auth: auth, issues: SyncIssueStore(), owner: first).uploadData(database: manager.database)
        let uploaded = try await manager.database.getCrudBatch()
        XCTAssertNil(uploaded)
        let uploads = requests.values.filter { $0.path == "/api/sync/upload" }
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads.first?.authorization, "Bearer \(first.uuidString)")
        XCTAssertEqual(uploads.first?.body["id"] as? String, first.uuidString.lowercased())
        _ = await auth.signOut()
        await auth.signIn(email: "second@example.test", password: "test-password")
        let secondQueue = try await manager.database.getCrudBatch()
        XCTAssertNotNil(secondQueue, "Uploading A must not acknowledge B's changes")
        _ = await auth.signOut()
    }

    func testLegacyDatabaseAndQueueStayWithItsOriginalOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let filename = directory.appendingPathComponent("legacy.sqlite").path
        let owner = UUID(), other = UUID()
        let legacy = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: filename)
        try await legacy.execute(sql: "insert into profiles (id, display_name) values (?, ?)", parameters: [owner.uuidString.lowercased(), "Existing offline changes"])
        let queue = try await crudData(legacy)
        try await legacy.close()
        let auth = try makeAuth()
        let manager = PowerSyncManager(auth: auth, issues: SyncIssueStore(), databaseFilename: filename)
        await auth.bootstrap(offlineAccount: manager.offlineAccount)
        XCTAssertNil(auth.currentUserID)
        try await manager.selectAccount(other)
        let otherRows = try await manager.database.getAll(sql: "select id from profiles", parameters: [], mapper: { try $0.getString(name: "id") })
        XCTAssertTrue(otherRows.isEmpty)
        try await manager.selectAccount(owner)
        let migratedQueue = try await crudData(manager.database)
        XCTAssertEqual(migratedQueue, queue)
        try await manager.releaseAccount()
    }

    func testRemovingOneAccountsDataLeavesAnotherAccountsQueueUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = UUID(), second = UUID()
        let manager = PowerSyncManager(auth: try makeAuth(), issues: SyncIssueStore(), databaseFilename: directory.appendingPathComponent("legacy.sqlite").path)
        try await manager.selectAccount(first)
        try await manager.database.execute(sql: "insert into profiles (id) values (?)", parameters: [first.uuidString.lowercased()])
        let queue = try await crudData(manager.database)
        try await manager.selectAccount(second)
        try await manager.database.execute(sql: "insert into profiles (id) values (?)", parameters: [second.uuidString.lowercased()])
        try await manager.deleteAccountData()
        try await manager.selectAccount(first)
        let remaining = try await crudData(manager.database)
        XCTAssertEqual(remaining, queue)
        try await manager.selectAccount(second)
        let removed = try await crudData(manager.database)
        let rows = try await manager.database.getAll(sql: "select id from profiles", parameters: [], mapper: { try $0.getString(name: "id") })
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(rows.isEmpty)
        try await manager.releaseAccount()
    }

    // MARK: Uploads

    func testAcceptedUploadIsSentWithTheOwnersTokenAndAcknowledged() async throws {
        let (auth, owner) = try await makeSignedInAuth(token: "owner-token")
        let database = makeDatabase()
        let profileID = owner.uuidString.lowercased()
        try await database.execute(sql: "insert into profiles (id) values (?)", parameters: [profileID])
        let requests = RequestLog()
        SyncStubProtocol.handler = { request in
            requests.append(request)
            return (200, Data(#"{"accepted":true}"#.utf8))
        }
        let issues = SyncIssueStore()

        try await APIConnector(auth: auth, issues: issues, owner: owner).uploadData(database: database)

        let crud = try await database.getCrudBatch()
        XCTAssertNil(crud)
        XCTAssertNil(issues.current)
        let sent = try XCTUnwrap(requests.values.first)
        XCTAssertEqual(sent.path, "/api/sync/upload")
        XCTAssertEqual(sent.authorization, "Bearer owner-token")
        XCTAssertEqual(sent.body["table"] as? String, "profiles")
        XCTAssertEqual(sent.body["id"] as? String, profileID)
        XCTAssertEqual(sent.body["op"] as? String, "put")
    }

    func testPermanentRejectionIsAcknowledgedAndReported() async throws {
        let (auth, owner) = try await makeSignedInAuth()
        let database = makeDatabase()
        try await database.execute(sql: "insert into profiles (id) values (?)", parameters: [owner.uuidString.lowercased()])
        SyncStubProtocol.handler = { _ in (400, Data(#"{"code":"23514","message":"check"}"#.utf8)) }
        let issues = SyncIssueStore()

        try await APIConnector(auth: auth, issues: issues, owner: owner).uploadData(database: database)

        let crud = try await database.getCrudBatch()
        XCTAssertNil(crud, "A permanent rejection must not block the queue")
        XCTAssertNotNil(issues.current)
    }

    func testTransientAuthAndRLSFailuresStayQueued() async throws {
        let responses: [(Int, String)] = [
            (503, #"{"code":"temporarily_unavailable"}"#),
            (500, "{}"),
            (403, #"{"code":"42501","message":"rls"}"#),
            (401, #"{"code":"sign_in_required"}"#),
            (400, #"{"code":"unexpected_code"}"#),
        ]
        for (status, body) in responses {
            let (auth, owner) = try await makeSignedInAuth()
            let database = makeDatabase()
            try await database.execute(sql: "insert into profiles (id) values (?)", parameters: [owner.uuidString.lowercased()])
            SyncStubProtocol.handler = { _ in (status, Data(body.utf8)) }
            let issues = SyncIssueStore()

            do {
                try await APIConnector(auth: auth, issues: issues, owner: owner).uploadData(database: database)
                XCTFail("HTTP \(status) must throw so PowerSync retries")
            } catch {}

            let crud = try await database.getCrudBatch()
            XCTAssertNotNil(crud, "HTTP \(status) must stay queued")
            XCTAssertNil(issues.current)
        }
    }

    func testUploadWithoutTheOwnersSessionStaysQueuedAndSendsNothing() async throws {
        let (auth, _) = try await makeSignedInAuth()
        let database = makeDatabase()
        let otherOwner = UUID()
        try await database.execute(sql: "insert into profiles (id) values (?)", parameters: [otherOwner.uuidString.lowercased()])
        let requests = RequestLog()
        SyncStubProtocol.handler = { request in
            requests.append(request)
            return (200, Data("{}".utf8))
        }

        do {
            try await APIConnector(auth: auth, issues: SyncIssueStore(), owner: otherOwner).uploadData(database: database)
            XCTFail("Expected an authentication error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired)
        }

        let crud = try await database.getCrudBatch()
        XCTAssertNotNil(crud)
        XCTAssertTrue(requests.values.isEmpty)
    }

    func testReadOnlyTableNeverUploads() async throws {
        let readOnly = try XCTUnwrap(
            DatabaseSchema.schema.tables.first { !$0.localOnly && !SyncAppConfiguration.writableTables.contains($0.name) },
            "Every app syncs at least one read-only snapshot table"
        )
        let (auth, owner) = try await makeSignedInAuth()
        let database = makeDatabase()
        try await database.execute(sql: "insert into \(readOnly.name) (id) values (?)", parameters: [UUID().uuidString.lowercased()])
        let requests = RequestLog()
        SyncStubProtocol.handler = { request in
            requests.append(request)
            return (200, Data("{}".utf8))
        }

        do {
            try await APIConnector(auth: auth, issues: SyncIssueStore(), owner: owner).uploadData(database: database)
            XCTFail("Expected unexpected table")
        } catch {
            XCTAssertEqual(error as? SyncUploadError, .unexpectedWritableTable(readOnly.name))
        }
        let crud = try await database.getCrudBatch()
        XCTAssertNotNil(crud)
        XCTAssertTrue(requests.values.isEmpty)
    }

    func testOnlyNonRetryableCodesArePermanent() {
        for code in ["23502", "23503", "23505", "23514"] {
            XCTAssertTrue(SyncAppConfiguration.permanentRejectionCodes.contains(code), code)
        }
        for code in ["42501", "sign_in_required", "temporarily_unavailable", "configuration", "invalid_request"] {
            XCTAssertFalse(APIConnector.isPermanentRejection(APIError(code: code, message: nil)), code)
        }
        XCTAssertFalse(APIConnector.isPermanentRejection(URLError(.notConnectedToInternet)))
        XCTAssertFalse(APIConnector.isPermanentRejection(SyncUploadError.unexpectedWritableTable("x")))
    }

    func testWritableTablesExistAndAreSynced() {
        let synced = Set(DatabaseSchema.schema.tables.filter { !$0.localOnly }.map(\.name))
        XCTAssertFalse(SyncAppConfiguration.writableTables.isEmpty)
        XCTAssertTrue(SyncAppConfiguration.writableTables.isSubset(of: synced))
        XCTAssertTrue(SyncAppConfiguration.writableTables.contains("profiles"))
    }

    // MARK: Helpers

    private func makeDatabase() -> PowerSyncDatabaseProtocol {
        let database = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: "shared-sync-\(UUID().uuidString).sqlite")
        databases.append(database)
        return database
    }

    private func crudData(_ database: PowerSyncDatabaseProtocol) async throws -> [String] {
        try await database.getAll(sql: "select data from ps_crud order by id", parameters: [], mapper: { try $0.getString(name: "data") })
    }

    private func makeAuth(store: SyncMemorySessionStore = SyncMemorySessionStore(), api: APIClient = APIClient()) throws -> AuthClient {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        return AuthClient(sessionStore: store, defaults: defaults, api: api)
    }

    private func makeSignedInAuth(token: String = "session-token") async throws -> (AuthClient, UUID) {
        let owner = UUID()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncStubProtocol.self]
        let api = APIClient(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://sync.example.test")!,
            configurationError: nil
        )
        let store = SyncMemorySessionStore()
        store.data = try JSONSerialization.data(withJSONObject: [
            "token": token,
            "user": ["id": owner.uuidString, "email": "sync@example.test"],
        ])
        let auth = try makeAuth(store: store, api: api)
        await auth.bootstrap(offlineAccount: { ([owner], false) })
        XCTAssertEqual(auth.currentUserID, owner)
        return (auth, owner)
    }
}

private struct RecordedRequest: Sendable {
    let path: String
    let authorization: String?
    let bodyData: Data

    var body: [String: Any] {
        (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
    }
}

private final class RequestLog: @unchecked Sendable {
    // Guarded by `lock`; URLProtocol callbacks arrive off the main actor.
    private let lock = NSLock()
    private var stored: [RecordedRequest] = []

    var values: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func append(_ request: RecordedRequest) {
        lock.lock(); defer { lock.unlock() }
        stored.append(request)
    }
}

private final class SyncStubProtocol: URLProtocol, @unchecked Sendable {
    // Guarded by `lock`; URLProtocol callbacks arrive off the main actor.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: (@Sendable (RecordedRequest) -> (Int, Data))?
    static var handler: (@Sendable (RecordedRequest) -> (Int, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let recorded = RecordedRequest(
            path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            bodyData: request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        )
        let (status, data) = Self.handler?(recorded) ?? (500, Data())
        if status == 0 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
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
private final class SyncMemorySessionStore: SessionStore {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data?) throws { self.data = data }
}
