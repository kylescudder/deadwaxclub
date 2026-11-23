import Foundation
import XCTest
#if canImport(Diald)
@testable import Diald
#elseif canImport(DeadWaxClub)
@testable import DeadWaxClub
#else
@testable import Moss
#endif

/// Behaviour of the shared billing core. Access is server-confirmed only, and
/// transactions are finished only after the server confirms them.
@MainActor
final class SharedBillingTests: XCTestCase {
    func testServerConfirmationActivatesAndFinishesTheTransaction() async throws {
        let mirror = FakeMirror([.success(TransactionMirrorResponse(verified: true, active: true))])
        let billing = try makeBilling(mirror: mirror)
        var finished = 0

        let confirmed = await billing.confirmLocallyVerifiedEntitlement(
            jwsRepresentation: "signed-transaction",
            finish: { finished += 1 }
        )

        XCTAssertTrue(confirmed)
        XCTAssertEqual(billing.subscriptionState, .active)
        XCTAssertTrue(billing.isSubscribed)
        XCTAssertTrue(billing.hasLocalSubscription)
        XCTAssertNil(billing.lastError)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(mirror.requests, ["signed-transaction"])
    }

    func testInactiveServerVerdictStaysVerifyingAndUnfinishedWithoutRetry() async throws {
        let mirror = FakeMirror([.success(TransactionMirrorResponse(verified: true, active: false))])
        let billing = try makeBilling(mirror: mirror)
        var finished = 0

        let confirmed = await billing.confirmLocallyVerifiedEntitlement(
            jwsRepresentation: "signed-transaction",
            finish: { finished += 1 }
        )

        XCTAssertFalse(confirmed)
        XCTAssertEqual(billing.subscriptionState, .verifying)
        XCTAssertTrue(billing.isVerifyingSubscription)
        XCTAssertFalse(billing.isSubscribed)
        XCTAssertTrue(billing.hasLocalSubscription)
        XCTAssertEqual(billing.lastError, BillingAppConfiguration.verificationPendingMessage)
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(mirror.requests.count, 1)
    }

    func testExplicitlyUnverifiedResponseNeverGrantsAccess() async throws {
        let mirror = FakeMirror([.success(TransactionMirrorResponse(verified: false, active: true))])
        let billing = try makeBilling(mirror: mirror)

        let confirmed = await billing.confirmLocallyVerifiedEntitlement(jwsRepresentation: "jws", finish: {})

        XCTAssertFalse(confirmed)
        XCTAssertEqual(billing.subscriptionState, .verifying)
        XCTAssertFalse(billing.isSubscribed)
    }

    func testConnectivityFailuresRetryThreeTimesWithBackoff() async throws {
        let mirror = FakeMirror([
            .failure(URLError(.notConnectedToInternet)),
            .failure(URLError(.timedOut)),
            .failure(URLError(.resourceUnavailable)),
        ])
        let pauses = PauseRecorder()
        let billing = try makeBilling(mirror: mirror, pauses: pauses)
        var finished = 0

        let confirmed = await billing.confirmLocallyVerifiedEntitlement(
            jwsRepresentation: "jws",
            finish: { finished += 1 }
        )

        XCTAssertFalse(confirmed)
        XCTAssertEqual(mirror.requests.count, 3)
        let recordedPauses = await pauses.values
        XCTAssertEqual(recordedPauses, [500_000_000, 1_000_000_000])
        XCTAssertEqual(billing.subscriptionState, .verifying)
        XCTAssertEqual(finished, 0)
    }

    func testTransientFailureThenConfirmationActivates() async throws {
        let mirror = FakeMirror([
            .failure(URLError(.networkConnectionLost)),
            .success(TransactionMirrorResponse(verified: nil, active: true)),
        ])
        let billing = try makeBilling(mirror: mirror)
        var finished = 0

        let confirmed = await billing.confirmLocallyVerifiedEntitlement(
            jwsRepresentation: "jws",
            finish: { finished += 1 }
        )

        XCTAssertTrue(confirmed)
        XCTAssertEqual(mirror.requests.count, 2)
        XCTAssertEqual(billing.subscriptionState, .active)
        XCTAssertEqual(finished, 1)
    }

    func testClientAndSignInErrorsAreNotRetried() async throws {
        for error: Error in [
            APIError(code: "invalid_request", message: "Rejected"),
            APIError(code: "sign_in_required", message: "Sign in"),
            BillingSyncError.unauthenticated,
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad")),
        ] {
            let mirror = FakeMirror([.failure(error)])
            let billing = try makeBilling(mirror: mirror)
            let confirmed = await billing.confirmLocallyVerifiedEntitlement(jwsRepresentation: "jws", finish: {})
            XCTAssertFalse(confirmed)
            XCTAssertEqual(mirror.requests.count, 1, "\(error) must not be retried")
            XCTAssertEqual(billing.subscriptionState, .verifying)
        }
    }

    func testRevocationIsMirroredBeforeItIsFinished() async throws {
        let mirror = FakeMirror([.success(TransactionMirrorResponse(verified: true, active: false))])
        let billing = try makeBilling(mirror: mirror)
        var finished = 0

        let persisted = await billing.persistInactiveTransaction(
            jwsRepresentation: "revoked-transaction",
            finish: { finished += 1 }
        )

        XCTAssertTrue(persisted)
        XCTAssertEqual(mirror.requests, ["revoked-transaction"])
        XCTAssertEqual(finished, 1)
        XCTAssertFalse(billing.isSubscribed)
    }

    func testUnstoredRevocationStaysUnfinishedForRedelivery() async throws {
        for failures in [
            [Error](repeating: URLError(.notConnectedToInternet), count: 3),
            [APIError(code: "invalid_transaction", message: "Rejected")],
        ] {
            let mirror = FakeMirror(failures.map { .failure($0) })
            let billing = try makeBilling(mirror: mirror)
            var finished = 0

            let persisted = await billing.persistInactiveTransaction(
                jwsRepresentation: "revoked-transaction",
                finish: { finished += 1 }
            )

            XCTAssertFalse(persisted)
            XCTAssertEqual(mirror.requests.count, failures.count)
            XCTAssertEqual(finished, 0)
        }
    }

    func testRevocationDoesNotTouchServerConfirmedState() async throws {
        let mirror = FakeMirror([
            .success(TransactionMirrorResponse(verified: true, active: true)),
            .success(TransactionMirrorResponse(verified: true, active: false)),
        ])
        let billing = try makeBilling(mirror: mirror)
        _ = await billing.confirmLocallyVerifiedEntitlement(jwsRepresentation: "current", finish: {})

        _ = await billing.persistInactiveTransaction(jwsRepresentation: "older-revoked", finish: {})

        // The follow-up entitlement sync, not the revocation mirror, decides access.
        XCTAssertEqual(billing.subscriptionState, .active)
        XCTAssertNil(billing.lastError)
    }

    func testNoActiveLocalEntitlementIsFree() async throws {
        let mirror = FakeMirror([])
        let billing = try makeBilling(mirror: mirror)
        _ = await billing.confirmLocallyVerifiedEntitlement(jwsRepresentation: "old", finish: {})

        await billing.reconcileEntitlements(activeJWSRepresentations: [])

        XCTAssertEqual(billing.subscriptionState, .free)
        XCTAssertFalse(billing.hasLocalSubscription)
        XCTAssertFalse(billing.isSubscribed)
        XCTAssertNil(billing.lastError)
    }

    func testUnconfirmedLocalEntitlementReportsVerificationPending() async throws {
        let mirror = FakeMirror([.success(TransactionMirrorResponse(verified: true, active: false))])
        let billing = try makeBilling(mirror: mirror)

        await billing.reconcileEntitlements(activeJWSRepresentations: ["current"])

        XCTAssertEqual(billing.subscriptionState, .verifying)
        XCTAssertTrue(billing.hasLocalSubscription)
        XCTAssertFalse(billing.isSubscribed)
        XCTAssertEqual(billing.lastError, BillingAppConfiguration.verificationPendingMessage)
    }

    func testConfirmedLocalEntitlementIsActive() async throws {
        let mirror = FakeMirror([.success(TransactionMirrorResponse(verified: true, active: true))])
        let billing = try makeBilling(mirror: mirror)

        await billing.reconcileEntitlements(activeJWSRepresentations: ["current"])

        XCTAssertEqual(billing.subscriptionState, .active)
        XCTAssertTrue(billing.isSubscribed)
        XCTAssertEqual(mirror.requests, ["current"])
    }

    func testAccessOverrideGrantsAccessUntilSignOut() async throws {
        let billing = try makeBilling(mirror: FakeMirror([]))
        XCTAssertFalse(billing.isSubscribed)

        billing.setAccessOverride(true)
        XCTAssertTrue(billing.isSubscribed)
        XCTAssertEqual(billing.subscriptionState, .free)

        billing.resetForSignOut()
        XCTAssertFalse(billing.hasAccessOverride)
        XCTAssertFalse(billing.isSubscribed)
        XCTAssertEqual(billing.subscriptionState, .free)
    }

    func testSignOutClearsServerConfirmedAccess() async throws {
        let mirror = FakeMirror([.success(TransactionMirrorResponse(verified: true, active: true))])
        let billing = try makeBilling(mirror: mirror)
        _ = await billing.confirmLocallyVerifiedEntitlement(jwsRepresentation: "jws", finish: {})

        billing.resetForSignOut()

        XCTAssertEqual(billing.subscriptionState, .free)
        XCTAssertFalse(billing.hasLocalSubscription)
        XCTAssertFalse(billing.isSubscribed)
        XCTAssertNil(billing.lastError)
    }

    func testLateConfirmationCannotRestoreAccessAfterAccountIsReleased() async throws {
        let mirror = ResetDuringMirror()
        let billing = BillingRepository(auth: try makeAuth(), mirror: mirror)
        mirror.beforeReply = { billing.resetForSignOut() }
        var finished = false
        let confirmed = await billing.confirmLocallyVerifiedEntitlement(jwsRepresentation: "previous-account", finish: { finished = true })
        XCTAssertFalse(confirmed)
        XCTAssertFalse(finished)
        XCTAssertEqual(billing.subscriptionState, .free)
        XCTAssertFalse(billing.isSubscribed)
    }

    func testMirrorResponseDecodesEveryAPIShape() throws {
        let decoder = JSONDecoder()
        let full = try decoder.decode(TransactionMirrorResponse.self, from: Data(#"{"verified":true,"active":true}"#.utf8))
        XCTAssertTrue(full.confirmsActiveEntitlement)
        let activeOnly = try decoder.decode(TransactionMirrorResponse.self, from: Data(#"{"active":true}"#.utf8))
        XCTAssertTrue(activeOnly.confirmsActiveEntitlement)
        let inactive = try decoder.decode(TransactionMirrorResponse.self, from: Data(#"{"active":false}"#.utf8))
        XCTAssertFalse(inactive.confirmsActiveEntitlement)
        let unverified = try decoder.decode(TransactionMirrorResponse.self, from: Data(#"{"verified":false,"active":true}"#.utf8))
        XCTAssertFalse(unverified.confirmsActiveEntitlement)
        XCTAssertThrowsError(try decoder.decode(TransactionMirrorResponse.self, from: Data(#"{"verified":true}"#.utf8)))
    }

    func testEntitlementIsActiveOnlyWhenUnrevokedAndUnexpired() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(SubscriptionEntitlement.isActive(revocationDate: nil, expirationDate: now.addingTimeInterval(60), now: now))
        XCTAssertTrue(SubscriptionEntitlement.isActive(revocationDate: nil, expirationDate: nil, now: now))
        XCTAssertFalse(SubscriptionEntitlement.isActive(revocationDate: nil, expirationDate: now, now: now))
        XCTAssertFalse(SubscriptionEntitlement.isActive(revocationDate: nil, expirationDate: now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(SubscriptionEntitlement.isActive(revocationDate: now, expirationDate: now.addingTimeInterval(60), now: now))
    }

    func testRetryPolicyClassification() {
        XCTAssertTrue(TransactionMirrorPolicy.isRetryable(URLError(.notConnectedToInternet)))
        XCTAssertTrue(TransactionMirrorPolicy.isRetryable(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        XCTAssertFalse(TransactionMirrorPolicy.isRetryable(APIError(code: "invalid_request", message: "")))
        XCTAssertFalse(TransactionMirrorPolicy.isRetryable(BillingSyncError.entitlementNotActive))
        XCTAssertEqual(TransactionMirrorPolicy.maxAttempts, 3)
    }

    func testAPIMirrorRequiresASignedInSessionBeforeCallingTheServer() async throws {
        let auth = try makeAuth()
        let mirror = APITransactionMirror(auth: auth)
        do {
            _ = try await mirror.mirror(jwsRepresentation: "jws")
            XCTFail("Expected unauthenticated")
        } catch {
            XCTAssertEqual(error as? BillingSyncError, .unauthenticated)
        }
    }

    func testProductIDComesFromTheAppHook() {
        XCTAssertEqual(BillingRepository.productID, BillingAppConfiguration.productID)
        XCTAssertFalse(BillingAppConfiguration.productID.isEmpty)
    }

    // MARK: - Helpers

    private func makeAuth() throws -> AuthClient {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        return AuthClient(sessionStore: EmptyBillingSessionStore(), defaults: defaults)
    }

    private func makeBilling(mirror: FakeMirror, pauses: PauseRecorder = PauseRecorder()) throws -> BillingRepository {
        BillingRepository(auth: try makeAuth(), mirror: mirror, pause: { await pauses.record($0) })
    }
}

@MainActor
private final class FakeMirror: TransactionMirroring {
    private var results: [Result<TransactionMirrorResponse, Error>]
    private(set) var requests: [String] = []

    init(_ results: [Result<TransactionMirrorResponse, Error>]) {
        self.results = results
    }

    func mirror(jwsRepresentation: String) async throws -> TransactionMirrorResponse {
        requests.append(jwsRepresentation)
        guard !results.isEmpty else { throw URLError(.cannotConnectToHost) }
        return try results.removeFirst().get()
    }
}

private actor PauseRecorder {
    private(set) var values: [UInt64] = []
    func record(_ value: UInt64) { values.append(value) }
}

private struct EmptyBillingSessionStore: SessionStore {
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws {}
}

@MainActor
private final class ResetDuringMirror: TransactionMirroring {
    var beforeReply: (() -> Void)?
    func mirror(jwsRepresentation: String) async throws -> TransactionMirrorResponse {
        beforeReply?()
        return TransactionMirrorResponse(verified: true, active: true)
    }
}
