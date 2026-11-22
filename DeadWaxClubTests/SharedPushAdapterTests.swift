import Foundation
import Security
import XCTest
#if canImport(Diald)
@testable import Diald
#else
@testable import DeadWaxClub
#endif

/// The shared push adapters around `PushRegistrationLifecycle`: lifecycle
/// ordering, session invalidation hooks, the installation ID, transport
/// selection and the app API transport.

@MainActor
final class SharedPushAdapterTests: XCTestCase {
    private let installationID = UUID(uuidString: "550d5a6b-7248-49da-a4dc-92db45608c07")!
    private let accountA = PushIdentity(principalID: "account-a", accessToken: "token-a")
    private let accountB = PushIdentity(principalID: "account-b", accessToken: "token-b")

    func testTokenBeforeSignInIsRetainedThenRegisteredOnActivation() async {
        let identity = FakePushIdentityProvider()
        let transport = FakePushRegistrationTransport()
        let registrar = FakeRemoteNotificationRegistrar()
        let lifecycle = makeLifecycle(identity: identity, transport: transport, registrar: registrar)

        await lifecycle.receivedDeviceToken(Data([0x01]))
        XCTAssertTrue(transport.calls.isEmpty)

        identity.identity = accountA
        await lifecycle.activate(isAuthorized: true)

        XCTAssertEqual(transport.calls, [.register(accountA, installationID, Data([0x01]))])
        XCTAssertEqual(registrar.registrationCount, 1)
    }

    func testActivationBeforeTokenWaitsForCallback() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = FakePushRegistrationTransport()
        let registrar = FakeRemoteNotificationRegistrar()
        let lifecycle = makeLifecycle(identity: identity, transport: transport, registrar: registrar)

        await lifecycle.activate(isAuthorized: true)
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertEqual(registrar.registrationCount, 1)

        await lifecycle.receivedDeviceToken(Data([0x00, 0xff]))
        XCTAssertEqual(transport.calls, [.register(accountA, installationID, Data([0x00, 0xff]))])
    }

    func testForegroundRefreshRequestsAPNsAndIdempotentlyRegistersLatestToken() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = FakePushRegistrationTransport()
        let registrar = FakeRemoteNotificationRegistrar()
        let lifecycle = makeLifecycle(identity: identity, transport: transport, registrar: registrar)

        await lifecycle.activate(isAuthorized: true)
        await lifecycle.receivedDeviceToken(Data([0x0a]))
        await lifecycle.refreshRegistration(isAuthorized: true)

        XCTAssertEqual(registrar.registrationCount, 2)
        XCTAssertEqual(
            transport.calls,
            [
                .register(accountA, installationID, Data([0x0a])),
                .register(accountA, installationID, Data([0x0a]))
            ]
        )
    }

    func testRepeatedIdenticalCallbackIsSafeAndIdempotentAtTransportBoundary() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = FakePushRegistrationTransport()
        let lifecycle = makeLifecycle(
            identity: identity,
            transport: transport,
            registrar: FakeRemoteNotificationRegistrar()
        )
        await lifecycle.activate(isAuthorized: true)

        await lifecycle.receivedDeviceToken(Data([0x01]))
        await lifecycle.receivedDeviceToken(Data([0x01]))

        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertEqual(transport.calls[0], transport.calls[1])
    }

    func testDeactivateAttemptsUnregisterAndClearsIdentityEvenOnFailure() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = FakePushRegistrationTransport()
        transport.unregisterError = TestError.expected
        var errors: [TestError] = []
        let lifecycle = makeLifecycle(
            identity: identity,
            transport: transport,
            registrar: FakeRemoteNotificationRegistrar(),
            errorHandler: { error in
                if let error = error as? TestError { errors.append(error) }
            }
        )
        await lifecycle.activate(isAuthorized: true)

        await lifecycle.deactivate()

        XCTAssertEqual(transport.calls, [.unregister(accountA, installationID)])
        XCTAssertNil(lifecycle.identity)
        XCTAssertEqual(errors, [.expected])
    }

    func testUnregisterRunsBeforeAuthCredentialsAreInvalidated() async throws {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = FakePushRegistrationTransport()
        let lifecycle = makeLifecycle(
            identity: identity,
            transport: transport,
            registrar: FakeRemoteNotificationRegistrar()
        )
        await lifecycle.activate(isAuthorized: true)
        var events: [String] = []
        transport.eventHandler = { events.append($0) }

        let auth = AuthClient()
        auth.beforeSessionInvalidation = { await lifecycle.deactivate() }
        _ = await auth.performSessionInvalidation {
            events.append("invalidate")
            return true
        }

        XCTAssertEqual(events, ["unregister", "invalidate"])
    }

    func testAccountSwitchUnregistersAThenRegistersBWithSameInstallation() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = FakePushRegistrationTransport()
        let lifecycle = makeLifecycle(
            identity: identity,
            transport: transport,
            registrar: FakeRemoteNotificationRegistrar()
        )
        await lifecycle.activate(isAuthorized: true)
        await lifecycle.receivedDeviceToken(Data([0xaa]))

        await lifecycle.deactivate()
        identity.identity = accountB
        await lifecycle.activate(isAuthorized: true)

        XCTAssertEqual(
            transport.calls,
            [
                .register(accountA, installationID, Data([0xaa])),
                .unregister(accountA, installationID),
                .register(accountB, installationID, Data([0xaa]))
            ]
        )
    }

    func testFailedUnregisterDoesNotPreventLaterAccountRebind() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = FakePushRegistrationTransport()
        let lifecycle = makeLifecycle(
            identity: identity,
            transport: transport,
            registrar: FakeRemoteNotificationRegistrar()
        )
        await lifecycle.activate(isAuthorized: true)
        await lifecycle.receivedDeviceToken(Data([0xbb]))
        transport.unregisterError = TestError.expected

        await lifecycle.deactivate()
        identity.identity = accountB
        await lifecycle.activate(isAuthorized: true)

        XCTAssertEqual(transport.calls.last, .register(accountB, installationID, Data([0xbb])))
    }

    func testDeniedAuthorizationChecksWithoutRegisteringOrPrompting() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = FakePushRegistrationTransport()
        let registrar = FakeRemoteNotificationRegistrar(authorizationAllowsRegistration: false)
        let lifecycle = makeLifecycle(identity: identity, transport: transport, registrar: registrar)

        await lifecycle.activate(isAuthorized: false)
        await lifecycle.refreshRegistration(isAuthorized: false)

        XCTAssertEqual(registrar.authorizationCheckCount, 0)
        XCTAssertEqual(registrar.registrationCount, 0)
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testSessionInvalidationHooksRunInOrderAndRestoreAfterFailure() async throws {
        let auth = AuthClient()
        var events: [String] = []
        auth.beforeSessionInvalidation = { events.append("before") }
        auth.afterSessionInvalidationFailure = { events.append("restore") }

        _ = await auth.performSessionInvalidation {
            events.append("invalidate")
            return true
        }
        XCTAssertEqual(events, ["before", "invalidate"])

        events = []
        do {
            let _: Void = try await auth.performSessionInvalidation {
                events.append("invalidate")
                throw TestError.expected
            }
            XCTFail("Expected invalidation to fail")
        } catch {
            XCTAssertEqual(error as? TestError, .expected)
        }
        XCTAssertEqual(events, ["before", "invalidate", "restore"])
    }

    func testAPISignOutRunsInvalidationHooksAndPreservesFailedSession() async {
        let store = TestSessionStore()
        let auth = AuthClient(sessionStore: store)
        var events: [String] = []
        auth.beforeSessionInvalidation = { events.append("unbind") }
        auth.afterSessionInvalidationFailure = { events.append("restore") }
        store.shouldFail = true
        let failed = await auth.signOut()
        XCTAssertFalse(failed)
        XCTAssertEqual(events, ["unbind", "restore"])
        store.shouldFail = false
        events = []
        let succeeded = await auth.signOut()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(events, ["unbind"])
        XCTAssertEqual(auth.state, .signedOut)
    }

    func testInstallationIDIsStableAndCorruptValueIsReplaced() throws {
        let store = FakeInstallationIDStore()
        let provider = KeychainPushInstallationIDProvider(store: store)

        let first = try provider.installationID()
        XCTAssertEqual(first, try provider.installationID())
        XCTAssertEqual(store.values[KeychainPushInstallationIDProvider.account], first.uuidString.lowercased())

        store.values[KeychainPushInstallationIDProvider.account] = "not-a-uuid"
        let replacement = try provider.installationID()
        XCTAssertNotEqual(replacement, first)
        XCTAssertEqual(
            store.values[KeychainPushInstallationIDProvider.account],
            replacement.uuidString.lowercased()
        )
    }

    func testInstallationIDStoreFailureDoesNotInventFallbackIdentity() {
        let provider = KeychainPushInstallationIDProvider(store: FailingInstallationIDStore())

        XCTAssertThrowsError(try provider.installationID()) { error in
            XCTAssertEqual(error as? TestError, .expected)
        }
    }

    func testRefreshRecoversIdentityAfterOfflineReauthentication() async {
        let identity = FakePushIdentityProvider()
        let transport = FakePushRegistrationTransport()
        let lifecycle = makeLifecycle(identity: identity, transport: transport, registrar: FakeRemoteNotificationRegistrar())
        await lifecycle.activate(isAuthorized: true)
        await lifecycle.receivedDeviceToken(Data([0xaa]))
        XCTAssertTrue(transport.calls.isEmpty)
        identity.identity = accountA
        await lifecycle.refreshRegistration(isAuthorized: true)
        XCTAssertEqual(transport.calls, [.register(accountA, installationID, Data([0xaa]))])
    }

    func testLogoutWaitsForInflightRegistrationAndDropsQueuedRefresh() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = FakePushRegistrationTransport()
        let registrar = FakeRemoteNotificationRegistrar()
        let lifecycle = makeLifecycle(identity: identity, transport: transport, registrar: registrar)
        await lifecycle.activate(isAuthorized: true)
        let gate = AsyncGate()
        transport.registerGate = gate
        let registration = Task { await lifecycle.receivedDeviceToken(Data([0xaa])) }
        await gate.waitUntilEntered()
        let refresh = Task { await lifecycle.refreshRegistration(isAuthorized: true) }
        let logout = Task { await lifecycle.deactivate() }
        // Yield until deactivation has synchronously invalidated registration.
        while lifecycle.identity != nil { await Task.yield() }
        XCTAssertEqual(transport.calls, [.register(accountA, installationID, Data([0xaa]))])
        gate.release()
        await registration.value
        await refresh.value
        await logout.value
        // Auth credentials can still exist until the invalidation hook returns.
        await lifecycle.refreshRegistration(isAuthorized: true)
        XCTAssertEqual(transport.calls, [
            .register(accountA, installationID, Data([0xaa])),
            .unregister(accountA, installationID)
        ])
        XCTAssertNil(lifecycle.identity)
        XCTAssertEqual(registrar.registrationCount, 1)
    }

    func testNewAccountRegistrationWaitsForOldAccountUnregister() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = FakePushRegistrationTransport()
        let lifecycle = makeLifecycle(identity: identity, transport: transport, registrar: FakeRemoteNotificationRegistrar())
        await lifecycle.activate(isAuthorized: true)
        await lifecycle.receivedDeviceToken(Data([0xbb]))
        let gate = AsyncGate()
        transport.unregisterGate = gate
        let logout = Task { await lifecycle.deactivate() }
        await gate.waitUntilEntered()
        identity.identity = accountB
        let activation = Task { await lifecycle.activate(isAuthorized: true) }
        await Task.yield()
        XCTAssertEqual(transport.calls.count, 2)
        gate.release()
        await logout.value
        await activation.value
        XCTAssertEqual(transport.calls, [
            .register(accountA, installationID, Data([0xbb])),
            .unregister(accountA, installationID),
            .register(accountB, installationID, Data([0xbb]))
        ])
        XCTAssertEqual(lifecycle.identity, accountB)
    }

    func testSignOutWhileIdentityLookupIsSuspendedDoesNotRestoreIdentity() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = FakePushRegistrationTransport()
        let registrar = FakeRemoteNotificationRegistrar()
        let lifecycle = makeLifecycle(identity: identity, transport: transport, registrar: registrar)
        await lifecycle.receivedDeviceToken(Data([0xaa]))
        let gate = AsyncGate()
        identity.gate = gate
        let activation = Task { await lifecycle.activate(isAuthorized: true) }
        await gate.waitUntilEntered()
        lifecycle.sessionEnded()
        gate.release()
        await activation.value
        XCTAssertNil(lifecycle.identity)
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertEqual(registrar.registrationCount, 0)
    }

    func testFailedAuthInvalidationCanReactivateTheSameAccount() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = FakePushRegistrationTransport()
        let lifecycle = makeLifecycle(identity: identity, transport: transport, registrar: FakeRemoteNotificationRegistrar())
        await lifecycle.receivedDeviceToken(Data([0x01]))
        await lifecycle.activate(isAuthorized: false)

        // AppServices installs these calls as the before-invalidation and
        // invalidation-failure hooks respectively.
        await lifecycle.deactivate()
        await lifecycle.activate(isAuthorized: false)

        XCTAssertEqual(transport.calls, [
            .register(accountA, installationID, Data([0x01])),
            .unregister(accountA, installationID),
            .register(accountA, installationID, Data([0x01])),
        ])
    }

    func testObservedSessionEndClearsCachedIdentity() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = FakePushRegistrationTransport()
        let lifecycle = makeLifecycle(identity: identity, transport: transport, registrar: FakeRemoteNotificationRegistrar())
        await lifecycle.activate(isAuthorized: false)

        lifecycle.sessionEnded()
        await lifecycle.receivedDeviceToken(Data([0x01]))

        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertNil(lifecycle.identity)
    }

    func testInstallationIDWriteFailureSurfacesWithoutUnstableFallback() {
        let store = FakeInstallationIDStore()
        store.writeError = TestError.expected
        let provider = KeychainPushInstallationIDProvider(store: store)

        XCTAssertThrowsError(try provider.installationID()) { error in
            XCTAssertEqual(error as? TestError, .expected)
        }
        XCTAssertNil(store.values[KeychainPushInstallationIDProvider.account])
    }

    func testInstallationIDKeychainItemComesFromTheAppHook() {
        XCTAssertEqual(KeychainPushInstallationIDProvider.account, "push-gateway.installation-id")
        let accessibility = PushAppConfiguration.installationIDKeychainAccessibility
        XCTAssertTrue(
            [kSecAttrAccessibleAfterFirstUnlock as String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String]
                .contains(accessibility)
        )
    }

    func testAPITransportRegistersAndUnregistersTheLatestTokenWithTheIdentitysBearer() async throws {
        let requests = PushAPIRequestLog()
        let auth = try await makeSignedInAuth(token: "token-a", requests: requests)
        let transport = APIPushRegistrationTransport(auth: auth)
        let currentIdentity = await auth.currentPushIdentity()
        let identity = try XCTUnwrap(currentIdentity)

        try await transport.unregister(installationID: installationID, identity: identity)
        XCTAssertTrue(requests.values.isEmpty, "Nothing to unregister before a registration")

        try await transport.register(
            installationID: installationID,
            deviceToken: Data([0x00, 0x0a, 0xff]),
            environment: .sandbox,
            identity: identity
        )
        try await transport.unregister(installationID: installationID, identity: identity)

        let sent = requests.values
        XCTAssertEqual(sent.map(\.method), ["POST", "DELETE"])
        XCTAssertEqual(sent.map(\.path), ["/api/devices", "/api/devices"])
        XCTAssertEqual(sent.map(\.authorization), ["Bearer token-a", "Bearer token-a"])
        XCTAssertEqual(sent[0].body["apns_token"] as? String, "000aff")
        XCTAssertEqual(sent[0].body["environment"] as? String, "sandbox")
        XCTAssertNotNil(sent[0].body["bundle_id"] as? String)
        XCTAssertNotNil(sent[0].body["device_name"] as? String)
        XCTAssertEqual(sent[1].body as? [String: String], ["apns_token": "000aff"])
    }

    func testAPITransportRefusesAStaleIdentityBearer() async throws {
        let requests = PushAPIRequestLog()
        let auth = try await makeSignedInAuth(token: "current-token", requests: requests)
        let transport = APIPushRegistrationTransport(auth: auth)
        let stale = PushIdentity(principalID: "account-a", accessToken: "old-token")

        do {
            try await transport.register(installationID: installationID, deviceToken: Data([0x01]), environment: .sandbox, identity: stale)
            XCTFail("A rotated bearer must not be used")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, "sign_in_required")
        }
        XCTAssertTrue(requests.values.isEmpty)
    }

    func testPushIdentityIsTheSignedInAccountWithItsToken() async throws {
        let auth = try await makeSignedInAuth(token: "token-a", requests: PushAPIRequestLog())
        let identity = await auth.currentPushIdentity()
        XCTAssertEqual(identity?.principalID, auth.currentUserID?.uuidString.lowercased())
        XCTAssertEqual(identity?.accessToken, "token-a")

        let signedOut = AuthClient(sessionStore: TestSessionStore(), defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let missing = await signedOut.currentPushIdentity()
        XCTAssertNil(missing)
    }

    private func makeSignedInAuth(token: String, requests: PushAPIRequestLog) async throws -> AuthClient {
        let owner = UUID()
        PushAPIStubProtocol.log = requests
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushAPIStubProtocol.self]
        let api = APIClient(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://push-api.example.test")!,
            configurationError: nil
        )
        let store = TestSessionStore()
        store.data = try JSONSerialization.data(withJSONObject: [
            "token": token,
            "user": ["id": owner.uuidString, "email": "push@example.test"],
        ])
        let auth = AuthClient(sessionStore: store, defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), api: api)
        await auth.bootstrap(offlineAccount: { ([owner], false) })
        XCTAssertEqual(auth.currentUserID, owner)
        return auth
    }

    private func makeLifecycle(
        identity: FakePushIdentityProvider,
        transport: FakePushRegistrationTransport,
        registrar: FakeRemoteNotificationRegistrar,
        errorHandler: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> PushRegistrationLifecycle {
        PushRegistrationLifecycle(
            identityProvider: identity,
            installationIDProvider: FixedInstallationIDProvider(id: installationID),
            transport: transport,
            remoteNotificationRegistrar: registrar,
            environment: .sandbox,
            reportError: { error, _ in errorHandler(error) }
        )
    }
}

private enum TestError: Error, Equatable {
    case expected
}

@MainActor
private final class FakePushIdentityProvider: PushIdentityProviding {
    var identity: PushIdentity?
    var gate: AsyncGate?

    init(identity: PushIdentity? = nil) {
        self.identity = identity
    }

    func currentPushIdentity() async -> PushIdentity? {
        let capturedIdentity = identity
        await gate?.enter()
        return capturedIdentity
    }
}

private struct FixedInstallationIDProvider: PushInstallationIDProviding {
    let id: UUID

    func installationID() throws -> UUID { id }
}

@MainActor
private final class FakeRemoteNotificationRegistrar: RemoteNotificationRegistering {
    private let authorizationAllowsRegistration: Bool
    private(set) var authorizationCheckCount = 0
    private(set) var registrationCount = 0

    init(authorizationAllowsRegistration: Bool = true) {
        self.authorizationAllowsRegistration = authorizationAllowsRegistration
    }

    func registerForRemoteNotifications() {
        authorizationCheckCount += 1
        if authorizationAllowsRegistration {
            registrationCount += 1
        }
    }
}

@MainActor
private final class FakePushRegistrationTransport: PushRegistrationTransport {
    enum Call: Equatable {
        case register(PushIdentity, UUID, Data)
        case unregister(PushIdentity, UUID)
    }

    private(set) var calls: [Call] = []
    var registerGate: AsyncGate?
    var unregisterGate: AsyncGate?
    var unregisterError: Error?
    var eventHandler: ((String) -> Void)?

    func register(
        installationID: UUID,
        deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws {
        calls.append(.register(identity, installationID, deviceToken))
        eventHandler?("register")
        await registerGate?.enter()
    }

    func unregister(
        installationID: UUID,
        identity: PushIdentity
    ) async throws {
        calls.append(.unregister(identity, installationID))
        eventHandler?("unregister")
        await unregisterGate?.enter()
        if let unregisterError { throw unregisterError }
    }
}

private final class FakeInstallationIDStore: PushInstallationIDStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String: String] = [:]

    var values: [String: String] {
        get { withLock { storedValues } }
        set { withLock { storedValues = newValue } }
    }

    func read(account: String) throws -> String? {
        withLock { storedValues[account] }
    }

    var writeError: Error? {
        get { withLock { storedWriteError } }
        set { withLock { storedWriteError = newValue } }
    }
    private var storedWriteError: Error?

    func write(account: String, value: String) throws {
        if let writeError { throw writeError }
        withLock { storedValues[account] = value }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private struct FailingInstallationIDStore: PushInstallationIDStoring {
    func read(account: String) throws -> String? { throw TestError.expected }
    func write(account: String, value: String) throws { throw TestError.expected }
}

@MainActor
private final class AsyncGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter() async {
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
private final class TestSessionStore: SessionStore {
    var shouldFail = false
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data?) throws {
        if shouldFail { throw TestError.expected }
        self.data = data
    }
}

private struct PushAPIRequest: Sendable {
    let method: String
    let path: String
    let authorization: String?
    let bodyData: Data

    var body: [String: Any] {
        (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
    }
}

private final class PushAPIRequestLog: @unchecked Sendable {
    // Guarded by `lock`; URLProtocol callbacks arrive off the main actor.
    private let lock = NSLock()
    private var stored: [PushAPIRequest] = []

    var values: [PushAPIRequest] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func append(_ request: PushAPIRequest) {
        lock.lock(); defer { lock.unlock() }
        stored.append(request)
    }
}

private final class PushAPIStubProtocol: URLProtocol, @unchecked Sendable {
    // Guarded by `lock`; URLProtocol callbacks arrive off the main actor.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedLog: PushAPIRequestLog?
    static var log: PushAPIRequestLog? {
        get { lock.lock(); defer { lock.unlock() }; return storedLog }
        set { lock.lock(); defer { lock.unlock() }; storedLog = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.log?.append(PushAPIRequest(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            bodyData: request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        ))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"accepted":true}"#.utf8))
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
