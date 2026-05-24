import SwiftUI

struct SubscriptionPaywallView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var createdCount: Int?

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.xl) {
                Spacer(minLength: Theme.Spacing.lg)

                Image("AppLogoIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                VStack(spacing: Theme.Spacing.sm) {
                    Text("Keep building your collection")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("Your first \(AppServices.freeRecordLimit) records are free. Subscribe to add unlimited owned and wishlist records.")
                        .font(.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: Theme.Spacing.sm) {
                    PrimaryButton(
                        title: subscribeTitle,
                        systemImage: "checkmark.seal.fill",
                        action: { Task { await subscribe() } }
                    )
                    .disabled(isPurchasing || services.billing.subscriptionProduct == nil)

                    Button {
                        Task { await restore() }
                    } label: {
                        if isRestoring {
                            ProgressView()
                        } else {
                            Text("Restore purchases")
                        }
                    }
                    .disabled(isRestoring || isPurchasing)
                }

                if services.billing.isLoadingProducts {
                    ProgressView()
                } else if services.billing.subscriptionProduct == nil {
                    Text("Subscription details are unavailable. Try again later.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else if let message = services.billing.lastError {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                if let createdCount {
                    Text("\(createdCount) records added")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }

                Spacer(minLength: Theme.Spacing.lg)
            }
            .padding(Theme.Spacing.xl)
            .background(Theme.Colors.background)
            .navigationTitle("Supporter Monthly")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
            .task {
                await services.billing.loadProducts()
                await services.billing.syncEntitlements()
                await loadCount()
                if services.billing.isSubscribed {
                    dismiss()
                }
            }
            .onChange(of: services.billing.isSubscribed) { _, subscribed in
                if subscribed { dismiss() }
            }
        }
    }

    private var subscribeTitle: String {
        guard let product = services.billing.subscriptionProduct else {
            return "Subscribe"
        }
        return "Subscribe \(product.displayPrice) / month"
    }

    private func subscribe() async {
        isPurchasing = true
        defer { isPurchasing = false }
        if await services.billing.purchase() {
            dismiss()
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        if await services.billing.restorePurchases() {
            dismiss()
        }
    }

    private func loadCount() async {
        guard let userID = services.auth.currentUserID?.lowerUUID else { return }
        createdCount = await services.records.createdRecordCount(userID: userID)
    }
}
