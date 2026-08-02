import Foundation
import PowerSync

struct IAPEntitlement: Identifiable, Hashable {
    var id: String { userID }

    let userID: String
    let bundleID: String?
    let productID: String
    let transactionID: String?
    let originalTransactionID: String?
    let status: String
    let expiresAt: Date?
    let revokedAt: Date?
    let environment: String?
    let signedAt: Date?
    let verifiedAt: Date?
    let verificationSource: String?
    let updatedAt: Date
}

extension IAPEntitlement {
    static func from(cursor: SqlCursor) -> IAPEntitlement? {
        do {
            return IAPEntitlement(
                userID: try cursor.getString(name: "id"),
                bundleID: try cursor.getStringOptional(name: "bundle_id"),
                productID: try cursor.getString(name: "product_id"),
                transactionID: try cursor.getStringOptional(name: "transaction_id"),
                originalTransactionID: try cursor.getStringOptional(name: "original_transaction_id"),
                status: try cursor.getString(name: "status"),
                expiresAt: parseDate(try cursor.getStringOptional(name: "expires_at")),
                revokedAt: parseDate(try cursor.getStringOptional(name: "revoked_at")),
                environment: try cursor.getStringOptional(name: "environment"),
                signedAt: parseDate(try cursor.getStringOptional(name: "signed_at")),
                verifiedAt: parseDate(try cursor.getStringOptional(name: "verified_at")),
                verificationSource: try cursor.getStringOptional(name: "verification_source"),
                updatedAt: parseDate(try cursor.getStringOptional(name: "updated_at")) ?? Date()
            )
        } catch {
            return nil
        }
    }
}
