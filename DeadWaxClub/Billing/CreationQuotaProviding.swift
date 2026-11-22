/// The app's lifetime creation allowance, read by the shared paywall. Each
/// app's creation-quota gate (server status, offline snapshot and pending
/// ledger) stays app-specific; this is the only part billing depends on.
@MainActor
protocol CreationQuotaProviding: AnyObject {
    /// Lifetime creations counted against the free allowance, including
    /// offline creations that are still waiting for the server.
    func lifetimeCreationCount() async throws -> Int
}
