import Foundation
import StoreKit
import UIKit

@MainActor
final class BillingRepository: ObservableObject {
    static let supporterMonthlyProductID = "club.deadwax.supporter.monthly"

    @Published private(set) var subscriptionProduct: Product?
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isSubscribed = false
    @Published private(set) var hasPremiumAccount = false
    @Published private(set) var hasStoreKitSubscription = false
    @Published private(set) var hasServerConfirmedEntitlement = false
    @Published private(set) var lastError: String?

    private let auth: AuthClient
    private var transactionTask: Task<Void, Never>?

    init(auth: AuthClient) {
        self.auth = auth
    }

    deinit { transactionTask?.cancel() }

    func start() {
        Log.breadcrumb("billing observer starting", category: "billing")
        transactionTask?.cancel()
        transactionTask = Task { [weak self] in
            guard let self else { return }
            for await result in Transaction.updates {
                await self.handle(result)
            }
        }
        Task {
            await loadProducts()
            await syncEntitlements()
        }
    }

    func resetForSignOut() {
        Log.breadcrumb("billing state reset for sign out", category: "billing")
        hasStoreKitSubscription = false
        hasServerConfirmedEntitlement = false
        hasPremiumAccount = false
        isSubscribed = false
        lastError = nil
    }

    func setPremiumAccount(_ premium: Bool) {
        guard hasPremiumAccount != premium else { return }
        hasPremiumAccount = premium
        updateSubscriptionState(source: "premiumOverride")
    }

    func loadProducts() async {
        Log.breadcrumb("billing products load started", category: "billing.products")
        lastError = nil
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let products = try await Product.products(for: [Self.supporterMonthlyProductID])
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
                guard case .verified(let transaction) = verification else {
                    lastError = "The purchase could not be verified."
                    return false
                }
                await sync(transaction, jwsRepresentation: verification.jwsRepresentation)
                await transaction.finish()
                await syncEntitlements()
                Log.event("purchase completed", category: "billing.purchase", metadata: ["isSubscribed": isSubscribed])
                return isSubscribed
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

    func syncEntitlements() async {
        Log.breadcrumb("billing entitlement sync started", category: "billing.entitlements")
        var active = false
        var serverConfirmed = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.supporterMonthlyProductID else { continue }
            if transaction.isActiveSubscriptionEntitlement {
                active = true
                serverConfirmed = await sync(transaction, jwsRepresentation: result.jwsRepresentation) || serverConfirmed
            }
        }
        hasStoreKitSubscription = active
        hasServerConfirmedEntitlement = active && serverConfirmed
        if active && !hasServerConfirmedEntitlement && lastError == nil {
            lastError = "Your subscription is active, but we could not verify it with the server yet. Please try again shortly."
        } else if !active {
            lastError = nil
        }
        updateSubscriptionState(source: "storeKit")
        Log.event("billing entitlement sync completed", category: "billing.entitlements", metadata: [
            "isSubscribed": isSubscribed,
            "storeKit": active,
            "serverConfirmed": hasServerConfirmedEntitlement,
        ])
    }

    private func updateSubscriptionState(source: String) {
        // StoreKit verification is immediate device evidence, but record
        // creation is enforced by Postgres. Do not promise unlimited database
        // creation until the verified transaction has been mirrored there.
        isSubscribed = hasPremiumAccount || (hasStoreKitSubscription && hasServerConfirmedEntitlement)
        Log.event("billing subscription state updated", category: "billing.entitlements", metadata: [
            "source": source,
            "storeKit": hasStoreKitSubscription,
            "premiumAccount": hasPremiumAccount,
            "isSubscribed": isSubscribed,
        ])
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        Log.breadcrumb("billing transaction update received", category: "billing.transactions")
        guard case .verified(let transaction) = result else { return }
        guard transaction.productID == Self.supporterMonthlyProductID else { return }
        await sync(transaction, jwsRepresentation: result.jwsRepresentation)
        await transaction.finish()
        await syncEntitlements()
    }

    private func sync(_ transaction: Transaction, jwsRepresentation: String) async -> Bool {
        Log.event("billing transaction sync started", category: "billing.syncTransaction", metadata: ["productID": transaction.productID])
        guard let token = await auth.currentAccessToken() else { return false }
        for attempt in 0..<3 {
            do {
                let url = AppSecrets.supabaseURL
                    .appendingPathComponent("functions")
                    .appendingPathComponent("v1")
                    .appendingPathComponent("iap-sync-transaction")
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(AppSecrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
                request.httpBody = try JSONEncoder().encode(TransactionSyncRequest(
                    signedTransactionInfo: jwsRepresentation,
                    source: "ios"
                ))

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw BillingSyncError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                let result = try JSONDecoder().decode(TransactionSyncResponse.self, from: data)
                guard result.active else { throw BillingSyncError.serverDidNotConfirm }
                lastError = nil
                Log.event("billing transaction sync completed", category: "billing.syncTransaction", metadata: ["productID": transaction.productID])
                return true
            } catch {
                Log.error(error, category: "billing.syncTransaction")
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
                }
            }
        }
        lastError = "Your subscription is active, but we could not verify it with the server yet. Please try again shortly."
        return false
    }
}

private struct TransactionSyncRequest: Encodable {
    let signedTransactionInfo: String
    let source: String
}

private struct TransactionSyncResponse: Decodable {
    let active: Bool
}

private enum BillingSyncError: LocalizedError {
    case badStatus(Int)
    case serverDidNotConfirm

    var errorDescription: String? {
        switch self {
        case .badStatus(let status):
            return "Subscription sync failed with status \(status)."
        case .serverDidNotConfirm:
            return "The server did not confirm the subscription."
        }
    }
}

private extension Transaction {
    var isActiveSubscriptionEntitlement: Bool {
        guard revocationDate == nil else { return false }
        if let expirationDate {
            return expirationDate > Date()
        }
        return true
    }
}
