import XCTest
@testable import AppUnderTest

@MainActor
final class SharedLoggingTests: XCTestCase {
    private let user = UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000000A")!
    private let app = AnalyticsApp(name: "Example", namespace: "com.example.app")

    func testSignedInSessionsIdentifyByTheAppNamespacedUserID() {
        XCTAssertEqual(
            Analytics.action(from: .unknown, to: .signedIn(userID: user, email: "listener@example.com"), in: app),
            .identify(distinctID: "com.example.app:a1b2c3d4-0000-4000-8000-00000000000a")
        )
    }

    func testTheSameUserIDInTwoAppsNeverSharesADistinctID() {
        let other = AnalyticsApp(name: "Other", namespace: "com.example.other")
        XCTAssertNotEqual(app.distinctID(for: user), other.distinctID(for: user))
    }

    func testBootstrappingKeepsTheStoredIdentity() {
        // AuthClient publishes .unknown before restoring a saved session.
        XCTAssertEqual(Analytics.action(from: nil, to: .unknown, in: app), .none)
        XCTAssertEqual(Analytics.action(from: .signedIn(userID: user, email: nil), to: .unknown, in: app), .none)
    }

    func testALaunchThatStartsSignedOutKeepsTheStoredIdentity() {
        XCTAssertEqual(Analytics.action(from: nil, to: .signedOut, in: app), .none)
        XCTAssertEqual(Analytics.action(from: .unknown, to: .signedOut, in: app), .none)
    }

    func testEndingASignedInSessionResetsTheIdentity() {
        XCTAssertEqual(Analytics.action(from: .signedIn(userID: user, email: nil), to: .signedOut, in: app), .reset)
    }

    func testEveryEventIsTaggedWithTheAppName() {
        let tagged = app.tagging(["$exception_level": "warning", "app": "Spoofed"])
        XCTAssertEqual(tagged["app"] as? String, "Example")
        XCTAssertEqual(tagged["$exception_level"] as? String, "warning")
    }

    func testTheAppNameComesFromTheExecutableAndFallsBackToTheBundleID() {
        XCTAssertEqual(
            AnalyticsApp(info: ["CFBundleExecutable": "Example"], bundleIdentifier: "com.example.app"),
            AnalyticsApp(name: "Example", namespace: "com.example.app")
        )
        XCTAssertEqual(AnalyticsApp(info: nil, bundleIdentifier: "com.example.app").name, "com.example.app")
    }

    func testTheCurrentAppUsesItsOwnBundleID() {
        XCTAssertEqual(AnalyticsApp.current.namespace, Bundle.main.bundleIdentifier)
        XCTAssertFalse(AnalyticsApp.current.name.isEmpty)
    }

    func testLoggingAndAnalyticsAreSafeWithoutAProjectToken() {
        // Simulator and pull-request builds leave POSTHOG_PROJECT_TOKEN empty.
        Log.breadcrumb("step", category: "test")
        Log.warning("analytics disabled", category: "test")
        Analytics.authStateChanged(.signedIn(userID: user, email: nil))
        Analytics.authStateChanged(.signedOut)
    }
}
