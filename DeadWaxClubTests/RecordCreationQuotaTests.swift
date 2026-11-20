import XCTest
@testable import DeadWaxClub

final class RecordCreationQuotaTests: XCTestCase {
    func testMissingSnapshotIsBlocked() {
        XCTAssertThrowsError(try RecordQuotaSnapshot.requireInitializedCount(nil)) { error in
            XCTAssertEqual(error as? RecordCreationError, .quotaSnapshotUnavailable)
        }
    }

    func testConfirmedZeroAllowsFirstReservation() throws {
        let count = try RecordQuotaSnapshot.requireInitializedCount(0)
        XCTAssertEqual(count + 0 + 1, 1)
        XCTAssertLessThanOrEqual(count + 0 + 1, 5)
    }

    func testPendingReservationsConsumeRemainingAllowance() throws {
        let count = try RecordQuotaSnapshot.requireInitializedCount(4)
        XCTAssertEqual(count + 1, 5)
        XCTAssertGreaterThan(count + 1 + 1, 5)
    }

    func testOnlineStatusIncludesLocalPendingCreations() {
        let serverStatus = RecordCreationStatus(
            lifetimeRecordCount: 3,
            freeLimit: 5,
            hasVerifiedEntitlement: false
        )
        XCTAssertEqual(
            serverStatus.includingPending(2),
            RecordCreationStatus(
                lifetimeRecordCount: 5,
                freeLimit: 5,
                hasVerifiedEntitlement: false
            )
        )
    }

    func testServerConfirmedBillingAllowsStaleEntitlementSnapshot() {
        XCTAssertTrue(RecordCreationAuthorization.allowsUnlimited(
            billingIsSubscribed: true,
            snapshotHasVerifiedEntitlement: false
        ))
        XCTAssertFalse(RecordCreationAuthorization.allowsUnlimited(
            billingIsSubscribed: false,
            snapshotHasVerifiedEntitlement: false
        ))
    }

    func testOnlyKnownPermanentUploadErrorsAreAcknowledged() {
        XCTAssertTrue(APIConnector.isPermanentRejection(
            APIError(code: "DW001", message: "quota reached")
        ))
        XCTAssertTrue(APIConnector.isPermanentRejection(
            APIError(code: "DW002", message: "invalid ownership")
        ))
        XCTAssertTrue(APIConnector.isPermanentRejection(
            APIError(code: "23514", message: "constraint failed")
        ))
        XCTAssertFalse(APIConnector.isPermanentRejection(
            APIError(code: "42501", message: "row-level security violation")
        ))
        XCTAssertFalse(APIConnector.isPermanentRejection(
            APIError(code: "PGRST001", message: "database unavailable")
        ))
        XCTAssertFalse(APIConnector.isPermanentRejection(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        ))
    }

    @MainActor
    func testTransientAuthBootstrapDoesNotClearOrDisconnect() {
        XCTAssertEqual(PowerSyncManager.action(for: .unknown), .none)
        XCTAssertEqual(PowerSyncManager.action(for: .signedOut), .disconnect)
    }
}
