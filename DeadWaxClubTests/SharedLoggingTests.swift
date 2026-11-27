import XCTest
@testable import AppUnderTest

@MainActor
final class SharedLoggingTests: XCTestCase {
    private let user = UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000000A")!

    func testSignedInSessionsIdentifyByLowercasedUserID() {
        XCTAssertEqual(
            Analytics.action(from: .unknown, to: .signedIn(userID: user, email: "listener@example.com")),
            .identify(userID: "a1b2c3d4-0000-4000-8000-00000000000a")
        )
    }

    func testBootstrappingKeepsTheStoredIdentity() {
        // AuthClient publishes .unknown before restoring a saved session.
        XCTAssertEqual(Analytics.action(from: nil, to: .unknown), .none)
        XCTAssertEqual(Analytics.action(from: .signedIn(userID: user, email: nil), to: .unknown), .none)
    }

    func testALaunchThatStartsSignedOutKeepsTheStoredIdentity() {
        XCTAssertEqual(Analytics.action(from: nil, to: .signedOut), .none)
        XCTAssertEqual(Analytics.action(from: .unknown, to: .signedOut), .none)
    }

    func testEndingASignedInSessionResetsTheIdentity() {
        XCTAssertEqual(Analytics.action(from: .signedIn(userID: user, email: nil), to: .signedOut), .reset)
    }

    func testLoggingAndAnalyticsAreSafeWithoutAProjectToken() {
        // Simulator and pull-request builds leave POSTHOG_PROJECT_TOKEN empty.
        Log.breadcrumb("step", category: "test")
        Log.warning("analytics disabled", category: "test")
        Analytics.authStateChanged(.signedIn(userID: user, email: nil))
        Analytics.authStateChanged(.signedOut)
    }
}
