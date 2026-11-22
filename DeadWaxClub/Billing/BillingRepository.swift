import Foundation
import StoreKit
import UIKit

/// Shared StoreKit 2 billing core. This file is identical in every app; the
/// product ID and copy live in `BillingAppConfiguration.swift`.
///
/// StoreKit's local verification is device evidence only. Server-backed access
/// (`subscriptionState == .active`) is granted only after the API has mirrored
/// an Apple-verified transaction through `/api/iap/transactions`. A locally
/// verified entitlement that the server has not confirmed stays `.verifying`.
/// Transactions are finished only after the server has stored them, so
/// StoreKit re-delivers an unconfirmed one through `Transaction.updates` and
/// it is mirrored again on the next launch. Refunds, revocations and expiries
/// are mirrored too, so the server stops granting access.
@MainActor
final class BillingRepository: ObservableObject {
    nonisolated static let productID = BillingAppConfiguration.productID

    @Published private(set) var subscriptionProduct: Product?
    @Published private(set) var isLoadingProducts = false
    /// StoreKit reports an active, locally verified entitlement for `productID`.
    @Published private(set) var hasLocalSubscription = false
    @Published private(set) var subscriptionState: SubscriptionAccessState = .free
    /// Access granted outside StoreKit, such as a server-side premium account.
    @Published private(set) var hasAccessOverride = false
    @Published private(set) var lastError: String?

    var isSubscribed: Bool { hasAccessOverride || subscriptionState == .active }
    var isVerifyingSubscription: Bool { subscriptionState == .verifying }
    var verificationStatusMessage: String { BillingAppConfiguration.verificationPendingMessage }

    private let auth: AuthClient
    private let mirror: any TransactionMirroring
    private let pause: @Sendable (UInt64) async -> Void
    private var transactionTask: Task<Void, Never>?

    init(
        auth: AuthClient,
        mirror: (any TransactionMirroring)? = nil,
        pause: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        self.auth = auth
        self.mirror = mirror ?? APITransactionMirror(auth: auth)
        self.pause = pause
    }

    deinit { transactionTask?.cancel() }

    func start() {
        Log.breadcrumb("billing observer starting", category: "billing")
        transactionTask?.cancel()
        transactionTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handle(result)
            }
        }
        Task {
            await loadProducts()
            if auth.currentUserID != nil {
                await syncEntitlements()
            }
        }
    }

    func resetForSignOut() {
        Log.breadcrumb("billing state reset for sign out", category: "billing")
        hasLocalSubscription = false
        hasAccessOverride = false
        subscriptionState = .free
        lastError = nil
    }

    func setAccessOverride(_ granted: Bool) {
        guard hasAccessOverride != granted else { return }
        hasAccessOverride = granted
        Log.event("billing access override updated", category: "billing.entitlements", metadata: [
            "granted": granted,
            "isSubscribed": isSubscribed,
        ])
    }

    func loadProducts() async {
        Log.breadcrumb("billing products load started", category: "billing.products")
        isLoadingProducts = true
        lastError = nil
        defer { isLoadingProducts = false }
        do {
            let products = try await Product.products(for: [Self.productID])
            subscriptionProduct = products.first
            Log.event("billing products load completed", category: "billing.products", metadata: ["count": products.count])
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "billing.products")
        }
    }

    @discardableResult
    func purchase() async -> Bool {
        Log.breadcrumb("purchase started", category: "billing.purchase")
        guard let product = subscriptionProduct else {
            await loadProducts()
            guard subscriptionProduct != nil else { return false }
            return await purchase()
        }
        guard let userID = auth.currentUserID else { return false }

        do {
            let result = try await product.purchase(options: [.appAccountToken(userID)])
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification,
                      transaction.productID == Self.productID,
                      transaction.isActiveSubscriptionEntitlement else {
                    lastError = "The purchase could not be verified by Apple."
                    return false
                }
                let confirmed = await confirmLocallyVerifiedEntitlement(
                    jwsRepresentation: verification.jwsRepresentation,
                    finish: { await transaction.finish() }
                )
                Log.event("purchase completed", category: "billing.purchase", metadata: ["isSubscribed": isSubscribed])
                return confirmed
            case .userCancelled, .pending:
                Log.breadcrumb("purchase cancelled or pending", category: "billing.purchase")
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "billing.purchase")
            return false
        }
    }

    @discardableResult
    func restorePurchases() async -> Bool {
        Log.breadcrumb("purchase restore started", category: "billing.restore")
        do {
            try await AppStore.sync()
            await syncEntitlements()
            Log.event("purchase restore completed", category: "billing.restore", metadata: ["isSubscribed": isSubscribed])
            return isSubscribed
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "billing.restore")
            return false
        }
    }

    func manageSubscriptions() async {
        do {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
                return
            }
            try await AppStore.showManageSubscriptions(in: scene)
            await syncEntitlements()
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "billing.manageSubscriptions")
        }
    }

    /// Re-checks StoreKit's current entitlements and mirrors any active one.
    /// Current entitlements are not finished here; purchases and
    /// `Transaction.updates` own finishing.
    func syncEntitlements() async {
        Log.breadcrumb("billing entitlement sync started", category: "billing.entitlements")
        var activeEntitlements: [String] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.productID,
                  transaction.isActiveSubscriptionEntitlement else { continue }
            activeEntitlements.append(result.jwsRepresentation)
        }
        await reconcileEntitlements(activeJWSRepresentations: activeEntitlements)
    }

    /// Applies the locally verified, active entitlements found by
    /// `syncEntitlements`. Internal so tests can drive it without StoreKit.
    func reconcileEntitlements(activeJWSRepresentations: [String]) async {
        lastError = nil
        for jwsRepresentation in activeJWSRepresentations {
            if await confirmLocallyVerifiedEntitlement(jwsRepresentation: jwsRepresentation, finish: {}) {
                logEntitlementSync()
                return
            }
        }

        if activeJWSRepresentations.isEmpty {
            hasLocalSubscription = false
            subscriptionState = .free
            lastError = nil
        } else {
            subscriptionState = .verifying
            lastError = BillingAppConfiguration.verificationPendingMessage
        }
        logEntitlementSync()
    }

    /// Moves a locally verified, active entitlement to `.verifying`, mirrors it
    /// to the server and, only once the server confirms it, finishes the
    /// transaction and grants `.active`. Internal so tests can drive it.
    @discardableResult
    func confirmLocallyVerifiedEntitlement(
        jwsRepresentation: String,
        finish: () async -> Void
    ) async -> Bool {
        hasLocalSubscription = true
        subscriptionState = .verifying
        guard await confirmWithServer(jwsRepresentation: jwsRepresentation) else { return false }
        await finish()
        subscriptionState = .active
        lastError = nil
        return true
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        Log.breadcrumb("billing transaction update received", category: "billing.transactions")
        guard case .verified(let transaction) = result,
              transaction.productID == Self.productID else { return }

        if transaction.isActiveSubscriptionEntitlement {
            await confirmLocallyVerifiedEntitlement(
                jwsRepresentation: result.jwsRepresentation,
                finish: { await transaction.finish() }
            )
        } else {
            // A refund, revocation or expiry: mirror it so the server's
            // entitlement row stops granting access, then re-check current
            // entitlements so access ends in this session.
            await persistInactiveTransaction(
                jwsRepresentation: result.jwsRepresentation,
                finish: { await transaction.finish() }
            )
            await syncEntitlements()
        }
    }

    /// Mirrors a revoked or expired transaction so the server records that it
    /// no longer grants access. The transaction is finished only once the
    /// server has stored it, whatever its verdict; otherwise StoreKit
    /// re-delivers it on the next launch. Internal so tests can drive it.
    @discardableResult
    func persistInactiveTransaction(
        jwsRepresentation: String,
        finish: () async -> Void
    ) async -> Bool {
        guard await mirrorWithRetry(jwsRepresentation: jwsRepresentation) != nil else { return false }
        await finish()
        return true
    }

    private func confirmWithServer(jwsRepresentation: String) async -> Bool {
        if let response = await mirrorWithRetry(jwsRepresentation: jwsRepresentation) {
            if response.confirmsActiveEntitlement { return true }
            Log.error(BillingSyncError.entitlementNotActive, category: "billing.syncTransaction")
        }
        subscriptionState = .verifying
        lastError = BillingAppConfiguration.verificationPendingMessage
        return false
    }

    /// Sends a signed transaction to the server, retrying only connectivity
    /// and 5xx failures. Returns the server's verdict once it has stored the
    /// transaction, or nil when it could not.
    private func mirrorWithRetry(jwsRepresentation: String) async -> TransactionMirrorResponse? {
        Log.breadcrumb("billing transaction sync started", category: "billing.syncTransaction")
        for attempt in 0..<TransactionMirrorPolicy.maxAttempts {
            do {
                let response = try await mirror.mirror(jwsRepresentation: jwsRepresentation)
                Log.breadcrumb("billing transaction sync completed", category: "billing.syncTransaction")
                return response
            } catch {
                guard TransactionMirrorPolicy.isRetryable(error),
                      attempt < TransactionMirrorPolicy.maxAttempts - 1 else {
                    Log.error(error, category: "billing.syncTransaction")
                    return nil
                }
                await pause(TransactionMirrorPolicy.retryDelayNanoseconds(afterAttempt: attempt))
            }
        }
        return nil
    }

    private func logEntitlementSync() {
        Log.event("billing entitlement sync completed", category: "billing.entitlements", metadata: [
            "state": String(describing: subscriptionState),
            "storeKit": hasLocalSubscription,
            "accessOverride": hasAccessOverride,
            "isSubscribed": isSubscribed,
        ])
    }
}

/// Mirrors a StoreKit transaction's signed JWS to the app's API.
@MainActor
protocol TransactionMirroring: AnyObject {
    func mirror(jwsRepresentation: String) async throws -> TransactionMirrorResponse
}

/// `/api/iap/transactions` response. Some APIs omit `verified`; an explicit
/// `false` is never treated as confirmation.
struct TransactionMirrorResponse: Decodable, Equatable, Sendable {
    let verified: Bool?
    let active: Bool

    var confirmsActiveEntitlement: Bool { active && verified != false }
}

@MainActor
final class APITransactionMirror: TransactionMirroring {
    private let auth: AuthClient

    init(auth: AuthClient) {
        self.auth = auth
    }

    func mirror(jwsRepresentation: String) async throws -> TransactionMirrorResponse {
        guard let token = await auth.currentAccessToken() else {
            throw BillingSyncError.unauthenticated
        }
        let data = try await auth.api.json(
            "api/iap/transactions",
            values: ["signedTransactionInfo": jwsRepresentation],
            expectedToken: token
        )
        return try JSONDecoder().decode(TransactionMirrorResponse.self, from: data)
    }
}

/// Retries only failures that can succeed later: connectivity and server
/// availability (`APIClient` reports 5xx responses as `URLError`). Client
/// errors, sign-in failures and an inactive server verdict are final.
enum TransactionMirrorPolicy {
    static let maxAttempts = 3

    static func retryDelayNanoseconds(afterAttempt attempt: Int) -> UInt64 {
        UInt64(500_000_000 * (1 << attempt))
    }

    static func isRetryable(_ error: Error) -> Bool {
        error is URLError || (error as NSError).domain == NSURLErrorDomain
    }
}

enum BillingSyncError: LocalizedError, Equatable {
    case unauthenticated
    case entitlementNotActive

    var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "Subscription confirmation requires an active sign-in."
        case .entitlementNotActive:
            return "The server could not confirm an active subscription."
        }
    }
}

enum SubscriptionEntitlement {
    static func isActive(revocationDate: Date?, expirationDate: Date?, now: Date = Date()) -> Bool {
        guard revocationDate == nil else { return false }
        if let expirationDate {
            return expirationDate > now
        }
        return true
    }
}

private extension Transaction {
    var isActiveSubscriptionEntitlement: Bool {
        SubscriptionEntitlement.isActive(revocationDate: revocationDate, expirationDate: expirationDate)
    }
}
