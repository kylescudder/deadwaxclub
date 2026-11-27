import XCTest
@testable import AppUnderTest

final class SharedLoggingTests: XCTestCase {
    func testBreadcrumbsKeepTheMostRecentEntriesOldestFirst() {
        let breadcrumbs = Breadcrumbs(limit: 3)
        for index in 1...5 {
            breadcrumbs.append(message: "step \(index)", category: "test", level: .info)
        }

        XCTAssertEqual(breadcrumbs.snapshot().map { $0["message"] }, ["step 3", "step 4", "step 5"])
    }

    func testBreadcrumbsRecordCategoryLevelAndTimestamp() throws {
        let breadcrumbs = Breadcrumbs()
        breadcrumbs.append(message: "sync failed", category: "sync", level: .warning)

        let entry = try XCTUnwrap(breadcrumbs.snapshot().first)
        XCTAssertEqual(entry["category"], "sync")
        XCTAssertEqual(entry["level"], "warning")
        XCTAssertNotNil(try Date(XCTUnwrap(entry["timestamp"]), strategy: .iso8601))
    }

    func testAnalyticsCallsAreSafeWithoutAProjectToken() {
        // Simulator and pull-request builds leave POSTHOG_PROJECT_TOKEN empty.
        Analytics.identify(userID: "00000000-0000-0000-0000-000000000000")
        Analytics.reset()
        Log.warning("analytics disabled", category: "test")
    }
}
