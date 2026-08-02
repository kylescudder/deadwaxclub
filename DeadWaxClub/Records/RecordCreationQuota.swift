import Foundation
import Supabase

enum RecordCreationError: Error, Equatable, Sendable {
    case quotaSnapshotUnavailable
    case freeLimitReached
    case missingCreator
    case unauthenticated
    case serverValidationFailure
}

struct RecordCreationStatus: Decodable, Equatable, Sendable {
    let lifetimeRecordCount: Int
    let freeLimit: Int
    let hasVerifiedEntitlement: Bool

    enum CodingKeys: String, CodingKey {
        case lifetimeRecordCount = "lifetime_record_count"
        case freeLimit = "free_limit"
        case hasVerifiedEntitlement = "has_verified_entitlement"
    }

    func includingPending(_ count: Int) -> RecordCreationStatus {
        RecordCreationStatus(
            lifetimeRecordCount: lifetimeRecordCount + count,
            freeLimit: freeLimit,
            hasVerifiedEntitlement: hasVerifiedEntitlement
        )
    }
}

enum RecordCreationAuthorization {
    static func allowsUnlimited(
        billingIsSubscribed: Bool,
        snapshotHasVerifiedEntitlement: Bool
    ) -> Bool {
        billingIsSubscribed || snapshotHasVerifiedEntitlement
    }
}

enum RecordCreationFailure {
    static func isConnectivityFailure(_ error: Error) -> Bool {
        if error is URLError || (error as NSError).domain == NSURLErrorDomain { return true }
        guard let error = error as? PostgrestError else { return false }
        return ["PGRST000", "PGRST001", "PGRST002", "PGRST003"].contains(error.code)
    }
}

enum RecordQuotaSnapshot {
    static func requireInitializedCount(_ count: Int?) throws -> Int {
        guard let count else { throw RecordCreationError.quotaSnapshotUnavailable }
        return count
    }
}
