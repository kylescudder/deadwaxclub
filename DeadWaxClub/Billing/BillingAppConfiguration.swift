import Foundation

/// Deadwax Club's values for the shared billing core (`BillingRepository`,
/// `SubscriptionPaywallView`).
enum BillingAppConfiguration {
    static let productID = "club.deadwax.supporter.monthly"
    static let verificationPendingMessage =
        "Your subscription is active, but we could not verify it with the server yet. Please try again shortly."

    static let paywallHeadline = "Keep building your collection"
    static let paywallMessage =
        "Your first \(AppServices.freeRecordLimit) records are free. Subscribe to add unlimited owned and wishlist records."
    static func usageText(count: Int) -> String {
        "\(count) \(count == 1 ? "record" : "records") added"
    }

    static let privacyPolicyURL = URL(string: "https://deadwaxclub.app/privacy")!
    static let termsOfUseURL = URL(string: "https://deadwaxclub.app/terms")!
}
