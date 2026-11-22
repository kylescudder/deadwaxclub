import Foundation
import XCTest
@testable import DeadWaxClub

@MainActor
final class PushRegistrationLifecycleTests: XCTestCase {
    private let installationID = UUID(uuidString: "550d5a6b-7248-49da-a4dc-92db45608c07")!
    private let accountA = PushIdentity(principalID: "account-a", accessToken: "token-a")
    private let accountB = PushIdentity(principalID: "account-b", accessToken: "token-b")

    func testTokenBeforeSignInIsRetainedThenRegisteredOnActivation() async {
        let identity = FakePushIdentityProvider(identity: nil)
        let transport = SpyPushRegistrationTransport()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)

        await lifecycle.receivedDeviceToken(Data([0x01]))
        var calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)

        identity.identity = accountA
        await lifecycle.activate(isAuthorized: false)

        calls = await transport.calls
        XCTAssertEqual(calls, [.register(principalID: "account-a", token: Data([0x01]))])
    }

    func testSignInBeforeTokenWaitsForAPNsCallback() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = SpyPushRegistrationTransport()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)

        await lifecycle.activate(isAuthorized: true)
        var calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)

        await lifecycle.receivedDeviceToken(Data([0x00, 0xff]))
        calls = await transport.calls
        XCTAssertEqual(calls, [.register(principalID: "account-a", token: Data([0x00, 0xff]))])
    }

    func testForegroundRefreshRegistersWithAPNsAndResubmitsLatestToken() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = SpyPushRegistrationTransport()
        let registrar = SpyRemoteNotificationRegistrar()
        let lifecycle = makeLifecycle(
            identity: identity,
            transport: transport,
            registrar: registrar
        )

        await lifecycle.receivedDeviceToken(Data([0x01]))
        await lifecycle.activate(isAuthorized: true)
        await lifecycle.refreshRegistration(isAuthorized: true)

        XCTAssertEqual(registrar.registrationCount, 2)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testRepeatedIdenticalTokenCallbackIsIdempotentlySubmitted() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = SpyPushRegistrationTransport()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        await lifecycle.activate(isAuthorized: false)

        await lifecycle.receivedDeviceToken(Data([0x01]))
        await lifecycle.receivedDeviceToken(Data([0x01]))

        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testDeactivateUnregistersBeforeAccountSwitchAndReusesInstallation() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = SpyPushRegistrationTransport()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        await lifecycle.receivedDeviceToken(Data([0x01]))
        await lifecycle.activate(isAuthorized: false)

        await lifecycle.deactivate()
        identity.identity = accountB
        await lifecycle.activate(isAuthorized: false)

        let calls = await transport.calls
        XCTAssertEqual(calls, [
            .register(principalID: "account-a", token: Data([0x01])),
            .unregister(principalID: "account-a"),
            .register(principalID: "account-b", token: Data([0x01])),
        ])
        let installationIDs = await transport.installationIDs
        XCTAssertEqual(Set(installationIDs), [installationID])
    }

    func testFailedUnregisterDoesNotBlockLaterAccountRebinding() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = SpyPushRegistrationTransport(failUnregister: true)
        let errors = ErrorCapture()
        let lifecycle = makeLifecycle(
            identity: identity,
            transport: transport,
            reportError: { error, category in errors.record(error, category: category) }
        )
        await lifecycle.receivedDeviceToken(Data([0x01]))
        await lifecycle.activate(isAuthorized: false)

        await lifecycle.deactivate()
        identity.identity = accountB
        await lifecycle.activate(isAuthorized: false)

        XCTAssertEqual(errors.categories, ["push.unregister"])
        let calls = await transport.calls
        XCTAssertEqual(calls.last, .register(principalID: "account-b", token: Data([0x01])))
    }

    func testFailedAuthInvalidationCanReactivateTheSameAccount() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = SpyPushRegistrationTransport()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        await lifecycle.receivedDeviceToken(Data([0x01]))
        await lifecycle.activate(isAuthorized: false)

        // AppServices installs these calls as the before-invalidation and
        // invalidation-failure hooks respectively.
        await lifecycle.deactivate()
        await lifecycle.activate(isAuthorized: false)

        let calls = await transport.calls
        XCTAssertEqual(calls, [
            .register(principalID: "account-a", token: Data([0x01])),
            .unregister(principalID: "account-a"),
            .register(principalID: "account-a", token: Data([0x01])),
        ])
    }

    func testObservedSessionEndClearsCachedIdentity() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = SpyPushRegistrationTransport()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        await lifecycle.activate(isAuthorized: false)

        lifecycle.sessionEnded()
        await lifecycle.receivedDeviceToken(Data([0x01]))

        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSessionInvalidationHooksWrapOperationAndRecoverFailure() async {
        let auth = AuthClient()
        var events: [String] = []
        auth.beforeSessionInvalidation = { events.append("unregister") }
        auth.afterSessionInvalidationFailure = { events.append("activate") }

        do {
            let _: Void = try await auth.performSessionInvalidation {
                events.append("invalidate")
                throw TestPushError.expected
            }
            XCTFail("Expected invalidation failure")
        } catch {
            XCTAssertEqual(error as? TestPushError, .expected)
        }

        XCTAssertEqual(events, ["unregister", "invalidate", "activate"])
    }

    func testDeniedAuthorizationDoesNotRegisterWithAPNs() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let registrar = SpyRemoteNotificationRegistrar()
        let lifecycle = makeLifecycle(
            identity: identity,
            transport: SpyPushRegistrationTransport(),
            registrar: registrar
        )

        await lifecycle.activate(isAuthorized: false)
        await lifecycle.refreshRegistration(isAuthorized: false)

        XCTAssertEqual(registrar.registrationCount, 0)
    }

    func testDisabledConfigurationSelectsOnlyAPITransport() async {
        let gateway = SpyPushRegistrationTransport()
        let api = SpyPushRegistrationTransport()
        let selected = PushRegistrationTransportSelector.select(
            configuration: nil,
            gateway: gateway,
            api: api
        )
        let lifecycle = makeLifecycle(
            identity: FakePushIdentityProvider(identity: accountA),
            transport: selected
        )

        await lifecycle.activate(isAuthorized: false)
        await lifecycle.receivedDeviceToken(Data([0x01]))

        let gatewayCalls = await gateway.calls
        let apiCalls = await api.calls
        XCTAssertTrue(gatewayCalls.isEmpty)
        XCTAssertEqual(apiCalls.count, 1)
    }

    func testConfiguredGatewaySelectsOnlyGatewayTransport() async {
        let gateway = SpyPushRegistrationTransport()
        let api = SpyPushRegistrationTransport()
        let configuration = PushGatewayConfiguration(
            baseURL: URL(string: "https://push.example.com")!,
            applicationID: "deadwaxclub"
        )
        let selected = PushRegistrationTransportSelector.select(
            configuration: configuration,
            gateway: gateway,
            api: api
        )
        let lifecycle = makeLifecycle(
            identity: FakePushIdentityProvider(identity: accountA),
            transport: selected
        )

        await lifecycle.activate(isAuthorized: false)
        await lifecycle.receivedDeviceToken(Data([0x01]))

        let gatewayCalls = await gateway.calls
        let apiCalls = await api.calls
        XCTAssertEqual(gatewayCalls.count, 1)
        XCTAssertTrue(apiCalls.isEmpty)
    }

    func testInstallationIDIsCreatedOnceAndStoredLowercase() throws {
        let store = FakeInstallationIDStore()
        let provider = KeychainPushInstallationIDProvider(store: store)

        let first = try provider.installationID()
        let second = try provider.installationID()

        XCTAssertEqual(first, second)
        XCTAssertEqual(store.storedValue, first.uuidString.lowercased())
    }

    func testCorruptInstallationIDIsReplaced() throws {
        let store = FakeInstallationIDStore(storedValue: "not-a-uuid")
        let provider = KeychainPushInstallationIDProvider(store: store)

        let replacement = try provider.installationID()

        XCTAssertEqual(store.storedValue, replacement.uuidString.lowercased())
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(store.storedValue)))
    }

    func testInstallationIDWriteFailureSurfacesWithoutUnstableFallback() {
        let store = FakeInstallationIDStore(writeError: TestPushError.expected)
        let provider = KeychainPushInstallationIDProvider(store: store)

        XCTAssertThrowsError(try provider.installationID()) { error in
            XCTAssertEqual(error as? TestPushError, .expected)
        }
        XCTAssertEqual(store.writeCount, 1)
    }

    func testRefreshCallbackAndLogoutUseRotatedBearerTokens() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let transport = SpyPushRegistrationTransport()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        await lifecycle.receivedDeviceToken(Data([0x01]))
        await lifecycle.activate(isAuthorized: true)
        identity.identity = PushIdentity(principalID: "account-a", accessToken: "refreshed")
        await lifecycle.refreshRegistration(isAuthorized: true)
        identity.identity = PushIdentity(principalID: "account-a", accessToken: "callback")
        await lifecycle.receivedDeviceToken(Data([0x02]))
        identity.identity = PushIdentity(principalID: "account-a", accessToken: "logout")
        await lifecycle.deactivate()
        let tokens = await transport.accessTokens
        XCTAssertEqual(tokens, ["token-a", "refreshed", "callback", "logout"])
    }

    func testLogoutDrainsInflightPUTAndInvalidatesQueuedRefresh() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let gate = AsyncPushGate()
        let transport = SpyPushRegistrationTransport(registerGate: gate)
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        await lifecycle.activate(isAuthorized: true)
        let registration = Task { await lifecycle.receivedDeviceToken(Data([0x01])) }
        await gate.waitUntilEntered()
        let refresh = Task { await lifecycle.refreshRegistration(isAuthorized: true) }
        var logoutStarted = false
        let logout = Task {
            logoutStarted = true
            await lifecycle.deactivate()
        }
        while !logoutStarted { await Task.yield() }
        let callsBeforeRelease = await transport.calls
        XCTAssertEqual(callsBeforeRelease, [.register(principalID: "account-a", token: Data([0x01]))])
        await gate.release()
        await registration.value
        await refresh.value
        await logout.value
        await lifecycle.refreshRegistration(isAuthorized: true)
        let calls = await transport.calls
        XCTAssertEqual(calls, [
            .register(principalID: "account-a", token: Data([0x01])),
            .unregister(principalID: "account-a")
        ])
    }

    func testNewAccountWaitsForOldAccountUnbind() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let gate = AsyncPushGate()
        let transport = SpyPushRegistrationTransport(unregisterGate: gate)
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        await lifecycle.receivedDeviceToken(Data([0x01]))
        await lifecycle.activate(isAuthorized: true)
        let logout = Task { await lifecycle.deactivate() }
        await gate.waitUntilEntered()
        identity.identity = accountB
        let activation = Task { await lifecycle.activate(isAuthorized: true) }
        await gate.release()
        await logout.value
        await activation.value
        let calls = await transport.calls
        XCTAssertEqual(calls, [
            .register(principalID: "account-a", token: Data([0x01])),
            .unregister(principalID: "account-a"),
            .register(principalID: "account-b", token: Data([0x01]))
        ])
    }

    func testSessionEndDuringIdentityLookupCannotRestoreRegistration() async {
        let identity = FakePushIdentityProvider(identity: accountA)
        let gate = AsyncPushGate()
        identity.gate = gate
        let transport = SpyPushRegistrationTransport()
        let registrar = SpyRemoteNotificationRegistrar()
        let lifecycle = makeLifecycle(identity: identity, transport: transport, registrar: registrar)
        await lifecycle.receivedDeviceToken(Data([0x01]))
        let activation = Task { await lifecycle.activate(isAuthorized: true) }
        await gate.waitUntilEntered()
        lifecycle.sessionEnded()
        await gate.release()
        await activation.value
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(registrar.registrationCount, 0)
    }

    func testAPISignOutRunsHooksAndRestoresAfterPersistenceFailure() async {
        let store = PushTestSessionStore()
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

    private func makeLifecycle(
        identity: FakePushIdentityProvider,
        transport: any PushRegistrationTransport,
        registrar: SpyRemoteNotificationRegistrar = SpyRemoteNotificationRegistrar(),
        reportError: @escaping (Error, String) -> Void = { _, _ in }
    ) -> PushRegistrationLifecycle {
        PushRegistrationLifecycle(
            identityProvider: identity,
            installationIDProvider: FixedInstallationIDProvider(value: installationID),
            transport: transport,
            remoteNotificationRegistrar: registrar,
            environment: .sandbox,
            reportError: reportError
        )
    }
}

@MainActor
private final class FakePushIdentityProvider: PushIdentityProviding {
    var identity: PushIdentity?
    var gate: AsyncPushGate?

    init(identity: PushIdentity?) {
        self.identity = identity
    }

    func currentPushIdentity() async -> PushIdentity? {
        let captured = identity
        await gate?.enter()
        return captured
    }
}

private struct FixedInstallationIDProvider: PushInstallationIDProviding {
    let value: UUID
    func installationID() throws -> UUID { value }
}

@MainActor
private final class SpyRemoteNotificationRegistrar: RemoteNotificationRegistering {
    private(set) var registrationCount = 0
    func registerForRemoteNotifications() { registrationCount += 1 }
}

private actor SpyPushRegistrationTransport: PushRegistrationTransport {
    enum Call: Equatable, Sendable {
        case register(principalID: String, token: Data)
        case unregister(principalID: String)
    }

    private(set) var calls: [Call] = []
    private(set) var installationIDs: [UUID] = []
    private let failUnregister: Bool
    private(set) var accessTokens: [String] = []
    private let registerGate: AsyncPushGate?
    private let unregisterGate: AsyncPushGate?

    init(failUnregister: Bool = false, registerGate: AsyncPushGate? = nil, unregisterGate: AsyncPushGate? = nil) {
        self.registerGate = registerGate
        self.unregisterGate = unregisterGate
        self.failUnregister = failUnregister
    }

    func register(
        installationID: UUID,
        deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws {
        installationIDs.append(installationID)
        calls.append(.register(principalID: identity.principalID, token: deviceToken))
        accessTokens.append(identity.accessToken)
        await registerGate?.enter()
    }

    func unregister(
        installationID: UUID,
        identity: PushIdentity
    ) async throws {
        installationIDs.append(installationID)
        calls.append(.unregister(principalID: identity.principalID))
        accessTokens.append(identity.accessToken)
        await unregisterGate?.enter()
        if failUnregister { throw TestPushError.expected }
    }
}

private final class FakeInstallationIDStore: PushInstallationIDStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private let writeError: Error?
    private var writes = 0

    init(storedValue: String? = nil, writeError: Error? = nil) {
        value = storedValue
        self.writeError = writeError
    }

    var storedValue: String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func readInstallationID() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func writeInstallationID(_ value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        writes += 1
        if let writeError { throw writeError }
        self.value = value
    }
}

@MainActor
private final class ErrorCapture {
    private(set) var categories: [String] = []
    func record(_ error: Error, category: String) { categories.append(category) }
}

private enum TestPushError: Error, Equatable {
    case expected
}

private actor AsyncPushGate {
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
private final class PushTestSessionStore: SessionStore {
    var shouldFail = false
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws {
        if shouldFail { throw TestPushError.expected }
    }
}
