import XCTest
import Supabase
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

    func testOnlyKnownPermanentUploadErrorsAreAcknowledged() {
        XCTAssertTrue(SupabaseConnector.isPermanentRejection(
            PostgrestError(code: "DW001", message: "quota reached")
        ))
        XCTAssertTrue(SupabaseConnector.isPermanentRejection(
            PostgrestError(code: "DW002", message: "invalid ownership")
        ))
        XCTAssertTrue(SupabaseConnector.isPermanentRejection(
            PostgrestError(code: "23514", message: "constraint failed")
        ))
        XCTAssertFalse(SupabaseConnector.isPermanentRejection(
            PostgrestError(code: "42501", message: "row-level security violation")
        ))
        XCTAssertFalse(SupabaseConnector.isPermanentRejection(
            PostgrestError(code: "PGRST001", message: "database unavailable")
        ))
        XCTAssertFalse(SupabaseConnector.isPermanentRejection(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        ))
    }

    func testTransientAuthBootstrapDoesNotClearOrDisconnect() {
        XCTAssertEqual(PowerSyncManager.action(for: .unknown), .none)
        XCTAssertEqual(PowerSyncManager.action(for: .signedOut), .disconnect)
    }
}
