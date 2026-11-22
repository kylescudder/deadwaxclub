/// Server-backed subscription access. `.verifying` means StoreKit verified an
/// active entitlement locally but the API has not confirmed it yet.
enum SubscriptionAccessState: Equatable, Sendable {
    case free
    case verifying
    case active
}
