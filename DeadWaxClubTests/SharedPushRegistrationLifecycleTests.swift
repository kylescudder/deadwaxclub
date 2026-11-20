import Foundation
import XCTest
#if canImport(Diald)
@testable import Diald
#else
@testable import DeadWaxClub
#endif

@MainActor
final class SharedPushRegistrationLifecycleTests: XCTestCase {
    func testRefreshCallbackAndUnbindUseCurrentCredentials() async {
        let fixture = Fixture()
        await fixture.lifecycle.activate(isAuthorized: true)
        await fixture.lifecycle.receivedDeviceToken(Data([1]))
        fixture.provider.identity = PushIdentity(principalID: "a", accessToken: "refresh")
        await fixture.lifecycle.refreshRegistration(isAuthorized: true)
        fixture.provider.identity = PushIdentity(principalID: "a", accessToken: "callback")
        await fixture.lifecycle.receivedDeviceToken(Data([2]))
        fixture.provider.identity = PushIdentity(principalID: "a", accessToken: "logout")
        await fixture.lifecycle.deactivate()
        let calls = await fixture.transport.calls
        XCTAssertEqual(calls, ["PUT:initial", "PUT:refresh", "PUT:callback", "DELETE:logout"])
    }

    func testLogoutWaitsForPutAndPreventsRefreshRebinding() async {
        let gate = Gate()
        let fixture = Fixture(gate: gate)
        await fixture.lifecycle.activate(isAuthorized: true)
        let registration = Task { await fixture.lifecycle.receivedDeviceToken(Data([1])) }
        await gate.waitUntilEntered()
        var started = false
        let logout = Task {
            started = true
            await fixture.lifecycle.deactivate()
        }
        while !started { await Task.yield() }
        let pending = await fixture.transport.calls
        XCTAssertEqual(pending, ["PUT:initial"])
        await gate.release()
        await registration.value
        await logout.value
        await fixture.lifecycle.refreshRegistration(isAuthorized: true)
        let calls = await fixture.transport.calls
        XCTAssertEqual(calls, ["PUT:initial", "DELETE:initial"])
    }

    func testSuspendedLookupCannotRestoreEndedSession() async {
        let fixture = Fixture()
        let gate = Gate()
        fixture.provider.gate = gate
        await fixture.lifecycle.receivedDeviceToken(Data([1]))
        let activation = Task { await fixture.lifecycle.activate(isAuthorized: true) }
        await gate.waitUntilEntered()
        fixture.lifecycle.sessionEnded()
        await gate.release()
        await activation.value
        let calls = await fixture.transport.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(fixture.registrar.count, 0)
    }

    func testUnbindNeverUsesAnotherAccountsCredentials() async {
        let fixture = Fixture()
        await fixture.lifecycle.activate(isAuthorized: true)
        await fixture.lifecycle.receivedDeviceToken(Data([1]))
        fixture.provider.identity = PushIdentity(principalID: "b", accessToken: "other")
        await fixture.lifecycle.deactivate()
        let calls = await fixture.transport.calls
        XCTAssertEqual(calls, ["PUT:initial"])
        XCTAssertEqual(fixture.errors, ["push.unregister"])
    }

    func testMissingCredentialsNeverReuseCachedBearer() async {
        let fixture = Fixture()
        await fixture.lifecycle.activate(isAuthorized: true)
        fixture.provider.identity = nil
        await fixture.lifecycle.receivedDeviceToken(Data([1]))
        let calls = await fixture.transport.calls
        XCTAssertTrue(calls.isEmpty)
        fixture.provider.identity = PushIdentity(principalID: "a", accessToken: "recovered")
        await fixture.lifecycle.refreshRegistration(isAuthorized: true)
        let recovered = await fixture.transport.calls
        XCTAssertEqual(recovered, ["PUT:recovered"])
    }
}

@MainActor
private final class Fixture {
    let provider = IdentityProvider()
    let registrar = Registrar()
    let transport: Transport
    var errors: [String] = []
    lazy var lifecycle = PushRegistrationLifecycle(
        identityProvider: provider,
        installationIDProvider: InstallationID(),
        transport: transport,
        remoteNotificationRegistrar: registrar,
        environment: .sandbox,
        reportError: { [weak self] _, category in self?.errors.append(category) }
    )
    init(gate: Gate? = nil) { transport = Transport(gate: gate) }
}

@MainActor
private final class IdentityProvider: PushIdentityProviding {
    var identity: PushIdentity? = PushIdentity(principalID: "a", accessToken: "initial")
    var gate: Gate?
    func currentPushIdentity() async -> PushIdentity? {
        let captured = identity
        await gate?.enter()
        return captured
    }
}

private struct InstallationID: PushInstallationIDProviding {
    func installationID() throws -> UUID {
        UUID(uuidString: "550d5a6b-7248-49da-a4dc-92db45608c07")!
    }
}

@MainActor
private final class Registrar: RemoteNotificationRegistering {
    var count = 0
    func registerForRemoteNotifications() { count += 1 }
}

private actor Transport: PushRegistrationTransport {
    let gate: Gate?
    private(set) var calls: [String] = []
    init(gate: Gate?) { self.gate = gate }
    func register(installationID: UUID, deviceToken: Data, environment: APNSEnvironment, identity: PushIdentity) async throws {
        calls.append("PUT:\(identity.accessToken)")
        await gate?.enter()
    }
    func unregister(installationID: UUID, identity: PushIdentity) async throws {
        calls.append("DELETE:\(identity.accessToken)")
    }
}

private actor Gate {
    private var entered = false
    private var released = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func enter() async {
        if released { return }
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
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
