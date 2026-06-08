import Foundation
import StoreKit
import UIKit

@MainActor
final class BillingRepository: ObservableObject {
    static let supporterMonthlyProductID = "club.deadwax.supporter.monthly"

    @Published private(set) var subscriptionProduct: Product?
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isSubscribed = false
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
        isSubscribed = false
        lastError = nil
    }

    func loadProducts() async {
        Log.breadcrumb("billing products load started", category: "billing.products")
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
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.supporterMonthlyProductID else { continue }
            await sync(transaction, jwsRepresentation: result.jwsRepresentation)
            if transaction.isActiveSubscriptionEntitlement {
                active = true
            }
        }
        isSubscribed = active
        Log.event("billing entitlement sync completed", category: "billing.entitlements", metadata: ["isSubscribed": isSubscribed])
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        Log.breadcrumb("billing transaction update received", category: "billing.transactions")
        guard case .verified(let transaction) = result else { return }
        guard transaction.productID == Self.supporterMonthlyProductID else { return }
        await sync(transaction, jwsRepresentation: result.jwsRepresentation)
        await transaction.finish()
        await syncEntitlements()
    }

    private func sync(_ transaction: Transaction, jwsRepresentation: String) async {
        Log.event("billing transaction sync started", category: "billing.syncTransaction", metadata: ["productID": transaction.productID])
        guard let token = await auth.currentAccessToken() else { return }
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

            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw BillingSyncError.badStatus(http.statusCode)
            }
            Log.event("billing transaction sync completed", category: "billing.syncTransaction", metadata: ["productID": transaction.productID])
        } catch {
            Log.error(error, category: "billing.syncTransaction")
        }
    }
}

private struct TransactionSyncRequest: Encodable {
    let signedTransactionInfo: String
    let source: String
}

private enum BillingSyncError: LocalizedError {
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badStatus(let status):
            return "Subscription sync failed with status \(status)."
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
