import Foundation
import XCTest
#if canImport(Diald)
@testable import Diald
#else
@testable import DeadWaxClub
#endif

@MainActor
final class SharedAuthClientTests: XCTestCase {
    func testMainScreensRequireASessionAndBlockUnauthorizedResponses() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = MemoryStore()
        let auth = AuthClient(sessionStore: store, defaults: defaults)
        XCTAssertFalse(auth.canAccessMainApp)
        await auth.bootstrap(offlineAccount: { ([], false) })
        XCTAssertFalse(auth.canAccessMainApp)

        let owner = UUID()
        store.data = session(user: owner, token: "expired-session")
        let restored = AuthClient(sessionStore: store, defaults: defaults)
        await restored.bootstrap(offlineAccount: { ([owner], false) })
        XCTAssertTrue(restored.canAccessMainApp)
        restored.api.onUnauthorized?()
        XCTAssertFalse(restored.canAccessMainApp)
        XCTAssertEqual(restored.currentUserID, owner)
        XCTAssertNotNil(store.data)
    }

    func testSavedSessionMustMatchOfflineOwner() async throws {
        let owner = UUID()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = MemoryStore()
        store.data = session(user: UUID(), token: "wrong-owner")
        let auth = AuthClient(sessionStore: store, defaults: defaults)
        await auth.bootstrap(offlineAccount: { ([owner], true) })
        XCTAssertNotNil(auth.lastError)
        XCTAssertNil(auth.currentUserID)
        let token = await auth.currentAccessToken()
        XCTAssertNil(token)
        XCTAssertNotNil(store.data)
    }

    func testOfflineOwnerIsPreservedWhenKeychainIsUnavailable() async throws {
        let owner = UUID()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = MemoryStore()
        store.failReads = true
        let auth = AuthClient(sessionStore: store, defaults: defaults)
        await auth.bootstrap(offlineAccount: { ([owner], true) })
        XCTAssertEqual(auth.currentUserID, owner)
        XCTAssertTrue(auth.requiresReauthentication)
        XCTAssertFalse(auth.canAccessMainApp)
        XCTAssertEqual(defaults.string(forKey: AuthClient.ownerKey), owner.uuidString.lowercased())
        let token = await auth.currentAccessToken()
        XCTAssertNil(token)
    }

    func testSavedOwnerCannotSupplyTokenForAnotherAccountOrRecovery() async throws {
        let owner = UUID()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = MemoryStore()
        store.data = session(user: owner, token: "valid-session")
        let auth = AuthClient(sessionStore: store, defaults: defaults)
        await auth.bootstrap(offlineAccount: { ([owner], false) })
        let valid = await auth.currentAccessToken(for: owner)
        XCTAssertEqual(valid, "valid-session")
        XCTAssertTrue(auth.canAccessMainApp)
        let wrong = await auth.currentAccessToken(for: UUID())
        XCTAssertNil(wrong)
        auth.isPasswordRecovery = true
        XCTAssertFalse(auth.canAccessMainApp)
        let recovery = await auth.currentAccessToken()
        XCTAssertNil(recovery)
    }

    func testStale401DoesNotInvalidateNewSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnauthorizedProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session, baseURL: URL(string: "https://auth.example.test")!, configurationError: nil)
        client.token = "old"
        var unauthorized = false
        client.onUnauthorized = { unauthorized = true }
        let started = expectation(description: "request started")
        UnauthorizedProtocol.onStart = { urlProtocol in
            Task { @MainActor in
                client.token = "new"
                started.fulfill()
                urlProtocol.finish()
            }
        }
        do { _ = try await client.request("api/me"); XCTFail("Expected 401") }
        catch { XCTAssertTrue(error is APIError) }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertFalse(unauthorized)
        XCTAssertEqual(client.token, "new")
        UnauthorizedProtocol.onStart = nil
    }

    func testExpectedTokenMismatchFailsBeforeNetwork() async {
        let client = APIClient(baseURL: URL(string: "https://auth.example.test")!, configurationError: nil)
        client.token = "new"
        do {
            _ = try await client.request("api/me", expectedToken: "old")
            XCTFail("Expected credential mismatch")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, "sign_in_required")
        }
    }

    func testReauthenticationAcceptsOriginalOwnerAndRejectsAnotherAccount() async throws {
        let owner = UUID()
        for candidate in [owner, UUID()] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [UnauthorizedProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = APIClient(session: session, baseURL: URL(string: "https://auth.example.test")!, configurationError: nil)
            let store = MemoryStore()
            let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
            let auth = AuthClient(sessionStore: store, defaults: defaults, api: client)
            await auth.bootstrap(offlineAccount: { ([owner], true) })
            let body = self.session(user: candidate, token: "reauthenticated")
            UnauthorizedProtocol.onStart = { urlProtocol in urlProtocol.finish(status: 200, data: body) }
            await auth.signIn(email: "auth@example.test", password: "test-password")
            if candidate == owner {
                XCTAssertFalse(auth.requiresReauthentication)
                XCTAssertTrue(auth.canAccessMainApp)
                let token = await auth.currentAccessToken()
                XCTAssertEqual(token, "reauthenticated")
                XCTAssertNotNil(store.data)
            } else {
                XCTAssertTrue(auth.requiresReauthentication)
                XCTAssertFalse(auth.canAccessMainApp)
                XCTAssertNotNil(auth.lastError)
                XCTAssertNil(store.data)
            }
            XCTAssertEqual(auth.currentUserID, owner)
            UnauthorizedProtocol.onStart = nil
        }
    }

    func testSignOutDuringPasswordRecoveryRevokesTheServerSession() async throws {
        let owner = UUID()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnauthorizedProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session, baseURL: URL(string: "https://auth.example.test")!, configurationError: nil)
        let store = MemoryStore()
        store.data = self.session(user: owner, token: "valid-session")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let auth = AuthClient(sessionStore: store, defaults: defaults, api: client)
        await auth.bootstrap(offlineAccount: { ([owner], false) })
        auth.isPasswordRecovery = true
        XCTAssertFalse(auth.canAccessMainApp)
        let revoked = expectation(description: "server sign-out")
        UnauthorizedProtocol.onStart = { urlProtocol in
            XCTAssertEqual(urlProtocol.request.url?.path, "/api/auth/sign-out")
            XCTAssertEqual(urlProtocol.request.value(forHTTPHeaderField: "Authorization"), "Bearer valid-session")
            revoked.fulfill()
            urlProtocol.finish(status: 200, data: Data("{}".utf8))
        }
        let signedOut = await auth.signOut()
        await fulfillment(of: [revoked], timeout: 5)
        XCTAssertTrue(signedOut)
        XCTAssertNil(store.data)
        XCTAssertEqual(auth.state, .signedOut)
        UnauthorizedProtocol.onStart = nil
    }

    private func session(user: UUID, token: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["token": token, "user": ["id": user.uuidString, "email": "auth@example.test"]])
    }
}

@MainActor
private final class MemoryStore: SessionStore {
    var data: Data?
    var failReads = false
    func read() throws -> Data? {
        if failReads { throw URLError(.userAuthenticationRequired) }
        return data
    }
    func write(_ data: Data?) throws { self.data = data }
}

private final class UnauthorizedProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var stored: (@Sendable (UnauthorizedProtocol) -> Void)?
    static var onStart: (@Sendable (UnauthorizedProtocol) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onStart?(self) }
    override func stopLoading() {}
    func finish(status: Int = 401, data: Data = Data("{\"code\":\"sign_in_required\"}".utf8)) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
