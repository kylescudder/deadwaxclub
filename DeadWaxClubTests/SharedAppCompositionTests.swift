import Foundation
import XCTest
#if canImport(Diald)
@testable import Diald
#else
@testable import DeadWaxClub
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
