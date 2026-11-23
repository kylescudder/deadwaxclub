import AuthenticationServices
import Foundation
import Network
import XCTest
#if canImport(Diald)
@testable import Diald
#elseif canImport(DeadWaxClub)
@testable import DeadWaxClub
#else
@testable import Moss
#endif

@MainActor
final class SharedAuthClientTests: XCTestCase {
    func testCancellingAppleSignInKeepsAccountAndClearsPreviousError() async throws {
        let owner = UUID()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = MemoryStore()
        store.data = session(user: owner, token: "saved-session")
        let auth = AuthClient(sessionStore: store, defaults: defaults)
        await auth.bootstrap(offlineAccount: { ([owner], true) })
        auth.api.onUnauthorized?()
        let saved = store.data
        auth.lastError = "A previous attempt failed"
        let request = ASAuthorizationAppleIDProvider().createRequest()
        auth.beginAppleSignIn(request: request)
        XCTAssertNil(auth.lastError)
        await auth.completeAppleSignIn(result: .failure(NSError(
            domain: ASAuthorizationError.errorDomain,
            code: ASAuthorizationError.canceled.rawValue
        )))
        XCTAssertNil(auth.lastError)
        XCTAssertEqual(auth.currentUserID, owner)
        XCTAssertTrue(auth.requiresReauthentication)
        XCTAssertFalse(auth.canAccessMainApp)
        XCTAssertEqual(store.data, saved)
        XCTAssertEqual(auth.api.token, "saved-session")
    }

    func testAppleSignInFailureStillShowsAnError() async {
        let auth = AuthClient(sessionStore: MemoryStore())
        await auth.completeAppleSignIn(result: .failure(NSError(
            domain: ASAuthorizationError.errorDomain,
            code: ASAuthorizationError.failed.rawValue
        )))
        XCTAssertNotNil(auth.lastError)
    }

    func testGoogleCancellationIsQuietButOtherWebSessionErrorsAreVisible() {
        let auth = AuthClient(sessionStore: MemoryStore())
        auth.lastError = "Previous error"
        auth.handleSocialSignInError(NSError(
            domain: ASWebAuthenticationSessionError.errorDomain,
            code: ASWebAuthenticationSessionError.canceledLogin.rawValue
        ), category: "auth.google")
        XCTAssertNil(auth.lastError)
        auth.handleSocialSignInError(NSError(
            domain: ASWebAuthenticationSessionError.errorDomain,
            code: ASWebAuthenticationSessionError.presentationContextInvalid.rawValue
        ), category: "auth.google")
        XCTAssertNotNil(auth.lastError)
        // A matching numeric code in another domain must remain a failure.
        auth.handleSocialSignInError(NSError(
            domain: "OtherError", code: ASAuthorizationError.canceled.rawValue
        ), category: "auth.apple")
        XCTAssertNotNil(auth.lastError)
    }

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

    func testSavedSessionSelectsItsOwnAccountWhilePreservingTheLegacyOwner() async throws {
        let owner = UUID()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = MemoryStore()
        let signedInOwner = UUID()
        store.data = session(user: signedInOwner, token: "another-owner")
        let auth = AuthClient(sessionStore: store, defaults: defaults)
        await auth.bootstrap(offlineAccount: { ([owner], true) })
        XCTAssertNil(auth.lastError)
        XCTAssertEqual(auth.currentUserID, signedInOwner)
        XCTAssertEqual(auth.legacyOwnerID, owner)
        let token = await auth.currentAccessToken()
        XCTAssertEqual(token, "another-owner")
        XCTAssertNotNil(store.data)
    }

    func testOfflineOwnerIsPreservedWhenKeychainIsUnavailable() async throws {
        let owner = UUID()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = MemoryStore()
        store.failReads = true
        let auth = AuthClient(sessionStore: store, defaults: defaults)
        await auth.bootstrap(offlineAccount: { ([owner], true) })
        XCTAssertNil(auth.currentUserID)
        XCTAssertEqual(auth.state, .signedOut)
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

    func testSignInCanSelectAnotherAccountWithoutDiscardingTheOriginalBinding() async throws {
        let owner = UUID()
        let candidate = UUID()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnauthorizedProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UnauthorizedProtocol.onStart = nil }
        let client = APIClient(session: session, baseURL: URL(string: "https://auth.example.test")!, configurationError: nil)
        let store = MemoryStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let auth = AuthClient(sessionStore: store, defaults: defaults, api: client)
        await auth.bootstrap(offlineAccount: { ([owner], true) })
        let body = self.session(user: candidate, token: "another-account")
        UnauthorizedProtocol.onStart = { urlProtocol in urlProtocol.finish(status: 200, data: body) }

        await auth.signIn(email: "auth@example.test", password: "test-password")

        XCTAssertNil(auth.lastError)
        XCTAssertEqual(auth.currentUserID, candidate)
        XCTAssertTrue(auth.canAccessMainApp)
        let token = await auth.currentAccessToken(for: candidate)
        XCTAssertEqual(token, "another-account")
        XCTAssertEqual(defaults.string(forKey: AuthClient.ownerKey), owner.uuidString.lowercased(), "Keep the original database bound to its owner")
    }

    func testAccountStorageFailureDoesNotPublishASession() async throws {
        let owner = UUID()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnauthorizedProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UnauthorizedProtocol.onStart = nil }
        let client = APIClient(session: session, baseURL: URL(string: "https://auth.example.test")!, configurationError: nil)
        let store = MemoryStore()
        let auth = AuthClient(sessionStore: store, defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), api: client)
        await auth.bootstrap(offlineAccount: { ([], false) })
        auth.prepareAccount = { _ in throw CocoaError(.fileWriteOutOfSpace) }
        let body = self.session(user: owner, token: "candidate")
        UnauthorizedProtocol.onStart = { $0.finish(status: 200, data: body) }
        await auth.signIn(email: "auth@example.test", password: "test-password")
        XCTAssertFalse(auth.canAccessMainApp)
        XCTAssertNil(auth.currentUserID)
        XCTAssertNil(auth.api.token)
        XCTAssertNil(store.data)
        XCTAssertNotNil(auth.lastError)
    }

    func testKeychainFailureAfterSelectingStorageFailsClosed() async throws {
        let first = UUID(), second = UUID()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnauthorizedProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UnauthorizedProtocol.onStart = nil }
        let client = APIClient(session: session, baseURL: URL(string: "https://auth.example.test")!, configurationError: nil)
        let store = MemoryStore()
        store.data = self.session(user: first, token: "previous")
        let auth = AuthClient(sessionStore: store, defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), api: client)
        await auth.bootstrap(offlineAccount: { ([first], false) })
        var selected: UUID?
        auth.prepareAccount = { selected = $0 }
        store.failWrites = true
        let body = self.session(user: second, token: "candidate")
        UnauthorizedProtocol.onStart = { $0.finish(status: 200, data: body) }
        await auth.signIn(email: "auth@example.test", password: "test-password")
        XCTAssertEqual(selected, second)
        XCTAssertFalse(auth.canAccessMainApp)
        XCTAssertNil(auth.currentUserID)
        XCTAssertNil(auth.api.token)
        XCTAssertNotNil(auth.lastError)
    }

    func testSignOutInvalidatesAnEarlierSignInResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnauthorizedProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UnauthorizedProtocol.onStart = nil }
        let auth = AuthClient(sessionStore: MemoryStore(), defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), api: APIClient(session: session, baseURL: URL(string: "https://auth.example.test")!, configurationError: nil))
        await auth.bootstrap(offlineAccount: { ([], false) })
        let started = expectation(description: "sign-in request")
        var pending: UnauthorizedProtocol?
        UnauthorizedProtocol.onStart = { request in
            Task { @MainActor in pending = request; started.fulfill() }
        }
        let signIn = Task { await auth.signIn(email: "auth@example.test", password: "test-password") }
        await fulfillment(of: [started], timeout: 5)
        let signedOut = await auth.signOut()
        XCTAssertTrue(signedOut)
        pending?.finish(status: 200, data: self.session(user: UUID(), token: "stale"))
        await signIn.value
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(auth.api.token)
        XCTAssertNil(auth.lastError)
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

    /// Better Auth checks Origin on any POST that carries a Cookie header, and the app sends none,
    /// so a stored session cookie turned sign-out into 403 MISSING_OR_NULL_ORIGIN. URLProtocol stubs
    /// bypass CFNetwork's cookie handling, so this runs over real HTTP on the loopback interface.
    func testSignOutSendsNoSessionCookieAfterSignIn() async throws {
        XCTAssertNil(APIClient.defaultSession.configuration.httpCookieStorage)
        XCTAssertFalse(APIClient.defaultSession.configuration.httpShouldSetCookies)
        XCTAssertEqual(APIClient.defaultSession.configuration.httpCookieAcceptPolicy, .never)
        let owner = UUID()
        let signInBody = String(decoding: session(user: owner, token: "bearer-session"), as: UTF8.self)
        let server = try LoopbackAuthServer { request in
            if request.path == "/api/auth/sign-in/email" {
                return (200, ["Set-Cookie": "app-auth.session_token=bearer-session.signature; Path=/; HttpOnly; SameSite=Lax; Max-Age=604800"], signInBody)
            }
            if request.headers["cookie"] != nil, request.headers["origin"] == nil {
                return (403, [:], #"{"code":"MISSING_OR_NULL_ORIGIN","message":"Missing or null Origin"}"#)
            }
            return (200, [:], #"{"success":true}"#)
        }
        let baseURL = try await server.start()
        defer {
            server.stop()
            APIClient.discardStoredCookies(for: baseURL)
        }
        // An install that signed in with an earlier build still holds the cookie in shared storage.
        let stale = try XCTUnwrap(HTTPCookie(properties: [
            .domain: try XCTUnwrap(baseURL.host), .path: "/", .name: "app-auth.session_token", .value: "stale.signature"
        ]))
        HTTPCookieStorage.shared.setCookie(stale)
        let client = APIClient(baseURL: baseURL, configurationError: nil)
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: baseURL) ?? [], [])

        let store = MemoryStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let auth = AuthClient(sessionStore: store, defaults: defaults, api: client)
        await auth.bootstrap(offlineAccount: { ([], false) })
        for _ in 0..<2 {
            await auth.signIn(email: "auth@example.test", password: "test-password")
            XCTAssertNil(auth.lastError)
            XCTAssertTrue(auth.canAccessMainApp)
            XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: baseURL) ?? [], [])
            let signedOut = await auth.signOut()
            XCTAssertTrue(signedOut, auth.lastError ?? "")
            XCTAssertEqual(auth.state, .signedOut)
            XCTAssertNil(store.data)
        }
        let requests = server.requests
        XCTAssertEqual(requests.map(\.path), ["/api/auth/sign-in/email", "/api/auth/sign-out", "/api/auth/sign-in/email", "/api/auth/sign-out"])
        for request in requests { XCTAssertNil(request.headers["cookie"], request.path) }
        XCTAssertEqual(requests.filter { $0.path == "/api/auth/sign-out" }.map { $0.headers["authorization"] }, ["Bearer bearer-session", "Bearer bearer-session"])
    }

    private func session(user: UUID, token: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["token": token, "user": ["id": user.uuidString, "email": "auth@example.test"]])
    }
}

@MainActor
private final class MemoryStore: SessionStore {
    var data: Data?
    var failReads = false
    var failWrites = false
    func read() throws -> Data? {
        if failReads { throw URLError(.userAuthenticationRequired) }
        return data
    }
    func write(_ data: Data?) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        self.data = data
    }
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

/// A minimal HTTP/1.1 server on 127.0.0.1, one request per connection. The lock guards the
/// listener's readiness flag and the recorded requests, which the listener queue writes and the
/// test reads.
private final class LoopbackAuthServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
    }
    typealias Reply = (status: Int, headers: [String: String], body: String)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackAuthServer")
    private let respond: @Sendable (Request) -> Reply
    private let lock = NSLock()
    private var received: [Request] = []
    private var started = false

    init(respond: @escaping @Sendable (Request) -> Reply) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.respond = respond
    }

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            listener.stateUpdateHandler = { [self] state in
                let result: Result<URL, Error>
                switch state {
                case .ready: result = .success(URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)")!)
                case .failed(let error): result = .failure(error)
                default: return
                }
                lock.lock()
                let first = !started
                started = true
                lock.unlock()
                if first { continuation.resume(with: result) }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                read(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { read(connection, buffer: buffer) }
                return
            }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let requestLine = lines[0].split(separator: " ")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "") ?? 0
            guard buffer.count - end.upperBound >= length else {
                if complete || error != nil { connection.cancel() } else { read(connection, buffer: buffer) }
                return
            }
            guard requestLine.count >= 2 else { connection.cancel(); return }
            let request = Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers)
            lock.lock()
            received.append(request)
            lock.unlock()
            let reply = respond(request)
            let body = Data(reply.body.utf8)
            var head = "HTTP/1.1 \(reply.status) Reply\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
            connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
