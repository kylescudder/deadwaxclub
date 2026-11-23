import Foundation
import Combine
import XCTest
#if canImport(Diald)
@testable import Diald
#elseif canImport(DeadWaxClub)
@testable import DeadWaxClub
#else
@testable import Moss
#endif

/// The shared app-composition pieces: quick-action replay, app-group storage
/// and the sign-in hooks every app must provide.
@MainActor
final class SharedAppCompositionTests: XCTestCase {
    func testQuickActionPersistedBeforeLaunchIsReplayedOnceOnActivation() throws {
        let action = try XCTUnwrap(AppQuickAction.allCases.first)
        let previous = UserDefaults.standard.string(forKey: AppQuickAction.pendingStorageKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: AppQuickAction.pendingStorageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppQuickAction.pendingStorageKey)
            }
        }
        let posted = PostedNames()
        let observer = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: nil) { note in
            posted.append(note.name)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        UserDefaults.standard.set(action.rawValue, forKey: AppQuickAction.pendingStorageKey)
        posted.reset()
        QuickActionRouter.activate()

        XCTAssertNil(UserDefaults.standard.string(forKey: AppQuickAction.pendingStorageKey))
        let afterReplay = posted.names
        XCTAssertFalse(afterReplay.isEmpty, "The persisted action must be routed")

        posted.reset()
        QuickActionRouter.activate()
        XCTAssertTrue(posted.names.filter { afterReplay.contains($0) }.isEmpty, "An action is replayed only once")
    }

    func testQuickActionRawValuesRoundTrip() {
        for action in AppQuickAction.allCases {
            XCTAssertEqual(AppQuickAction(rawValue: action.rawValue), action)
        }
        XCTAssertFalse(AppQuickAction.pendingStorageKey.isEmpty)
    }

    func testAppGroupStoreRoundTripsCodableValues() {
        let key = "shared-composition-tests.\(UUID().uuidString)"
        defer { AppGroupStore.remove(forKey: key) }

        XCTAssertNil(AppGroupStore.load([String].self, forKey: key))
        AppGroupStore.save(["a", "b"], forKey: key)
        XCTAssertEqual(AppGroupStore.load([String].self, forKey: key), ["a", "b"])
        XCTAssertNil(AppGroupStore.load(Int.self, forKey: key), "A value of another type is ignored")
        AppGroupStore.remove(forKey: key)
        XCTAssertNil(AppGroupStore.load([String].self, forKey: key))
    }

    func testSwitchingAccountsReplacesTheRepositoriesAndRestoresTheirOfflineProfile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompositionAuthProtocol.self]
        let first = UUID(), second = UUID()
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); CompositionAuthProtocol.owner = nil }
        let auth = AuthClient(sessionStore: CompositionSessionStore(), defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), api: APIClient(session: session, baseURL: URL(string: "https://composition.example.test")!, configurationError: nil))
        let services = AppServices(auth: auth, databaseFilename: directory.appendingPathComponent("legacy.sqlite").path)
        await auth.bootstrap(offlineAccount: services.sync.offlineAccount)
        CompositionAuthProtocol.owner = first
        await auth.signIn(email: "first@example.test", password: "test-password")
        XCTAssertTrue(auth.canAccessMainApp)
        let originalProfile = services.profile
        let originalDatabase = services.sync.database
        try await originalDatabase.execute(sql: "insert into profiles (id, display_name) values (?, ?)", parameters: [first.uuidString.lowercased(), "First offline name"])
        let loaded = expectation(description: "first account profile is visible")
        let firstWatch = services.profile.$profile.sink { if $0?.displayName == "First offline name" { loaded.fulfill() } }
        await fulfillment(of: [loaded], timeout: 5)
        firstWatch.cancel()
        let signedOut = await auth.signOut()
        XCTAssertTrue(signedOut)
        XCTAssertNil(services.profile.profile)
        CompositionAuthProtocol.owner = second
        await auth.signIn(email: "second@example.test", password: "test-password")
        XCTAssertTrue(auth.canAccessMainApp)
        XCTAssertFalse(originalProfile === services.profile)
        XCTAssertNil(services.profile.profile, "B must not briefly see A's profile")
        do {
            try await originalDatabase.execute(sql: "update profiles set display_name = 'stale task'", parameters: [])
            XCTFail("A repository retained by a dismissed view must hold a closed database")
        } catch {}
        _ = await auth.signOut()
        CompositionAuthProtocol.owner = first
        await auth.signIn(email: "first@example.test", password: "test-password")
        let restored = expectation(description: "returning account's offline profile is restored")
        let restoredWatch = services.profile.$profile.sink { if $0?.displayName == "First offline name" { restored.fulfill() } }
        await fulfillment(of: [restored], timeout: 5)
        restoredWatch.cancel()
        _ = await auth.signOut()
    }

    func testSignInHooksAreProvided() {
        XCTAssertFalse(AuthAppConfiguration.signInLogo.imageName.isEmpty)
        XCTAssertGreaterThan(AuthAppConfiguration.signInLogo.size, 0)
        XCTAssertGreaterThanOrEqual(AuthAppConfiguration.signInLogo.cornerRadius, 0)
        XCTAssertFalse(AuthAppConfiguration.signInTitle.isEmpty)
        XCTAssertFalse(AuthAppConfiguration.signInTagline.isEmpty)
    }
}

private final class PostedNames: @unchecked Sendable {
    // Guarded by `lock`; notifications may be delivered on any thread.
    private let lock = NSLock()
    private var stored: [Notification.Name] = []

    var names: [Notification.Name] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func append(_ name: Notification.Name) {
        lock.lock(); defer { lock.unlock() }
        stored.append(name)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        stored = []
    }
}

@MainActor
private final class CompositionSessionStore: SessionStore {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data?) throws { self.data = data }
}

private final class CompositionAuthProtocol: URLProtocol, @unchecked Sendable {
    // Guarded because URLProtocol responds on its URLSession callback queue.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedOwner: UUID?
    static var owner: UUID? {
        get { lock.lock(); defer { lock.unlock() }; return storedOwner }
        set { lock.lock(); defer { lock.unlock() }; storedOwner = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = Data("{}".utf8)
        if request.url?.path == "/api/auth/sign-in/email", let owner = Self.owner {
            data = try! JSONSerialization.data(withJSONObject: ["token": owner.uuidString, "user": ["id": owner.uuidString]])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
