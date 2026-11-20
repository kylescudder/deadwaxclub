import PowerSync
import XCTest
@testable import DeadWaxClub

@MainActor
final class OfflineAccountTests: XCTestCase {
    func testOfflineUpgradeKeepsTheOriginalAccountAndQueue() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let originalOwner = UUID()
        let database = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: ":memory:")
        try await database.execute(
            sql: "insert into collections (id, name, created_by) values (?, ?, ?)",
            parameters: [UUID().lowerUUID, "Offline collection", originalOwner.lowerUUID]
        )
        let auth = AuthClient(sessionStore: EmptySessionStore(), defaults: defaults)

        await auth.bootstrap(offlineAccount: {
            let pending = try await database.getCrudBatch() != nil
            return ([originalOwner], pending)
        })

        XCTAssertEqual(auth.currentUserID, originalOwner)
        XCTAssertTrue(auth.requiresReauthentication)
        let token = await auth.currentAccessToken()
        XCTAssertNil(token)
        let batch = try await database.getCrudBatch()
        XCTAssertEqual(batch?.crud.count, 1)
        XCTAssertEqual(batch?.crud.first?.table, "collections")
        try await database.close()
    }

    func testUnknownQueueOwnerRequiresRecoveryBeforeSignIn() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let auth = AuthClient(sessionStore: EmptySessionStore(), defaults: defaults)

        await auth.bootstrap(offlineAccount: { ([], true) })

        XCTAssertEqual(auth.state, .unknown)
        XCTAssertNotNil(auth.lastError)
    }
}

@MainActor
private struct EmptySessionStore: SessionStore {
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws {}
}
