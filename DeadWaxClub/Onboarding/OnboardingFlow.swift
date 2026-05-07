import Foundation
import SwiftUI

/// The set of one-time onboarding sheets a newly signed-in user might see,
/// in display order. Empty array means everything's already done.
enum OnboardingStep: Identifiable, Hashable {
    case displayName
    case discogsToken
    case enableNotifications

    var id: Self { self }
}

@MainActor
final class OnboardingCoordinator: ObservableObject {
    @AppStorage("onboarding.discogsTokenSeen") private var discogsTokenSeen: Bool = false
    @AppStorage("onboarding.notificationsSeen") private var notificationsSeen: Bool = false
    /// Latches once we've ever seen a non-empty displayName for this user
    /// on this device. Persisted across launches so subsequent cold starts
    /// don't flash the sheet during the brief window between watcher
    /// emission and PowerSync's first checkpoint apply. Cleared by sign-out.
    @AppStorage("onboarding.displayNameSeen") private var displayNameSeen: Bool = false

    @Published var current: OnboardingStep?

    /// Decide what to show right now given current profile + token state.
    /// Called whenever the user signs in or completes a step.
    /// `profileLoaded` is the gate that prevents flashing `.displayName`
    /// before the local DB has had a chance to surface the row.
    func reconcile(profileLoaded: Bool, profileDisplayName: String?, hasDiscogsToken: Bool, notificationsAuthorized: Bool) {
        guard profileLoaded else { return }
        let trimmed = (profileDisplayName ?? "").trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { displayNameSeen = true }

        if !displayNameSeen && trimmed.isEmpty {
            current = .displayName
        } else if !discogsTokenSeen && !hasDiscogsToken {
            current = .discogsToken
        } else if !notificationsSeen && !notificationsAuthorized {
            current = .enableNotifications
        } else {
            current = nil
        }
    }

    func markDiscogsTokenSeen() { discogsTokenSeen = true }
    func markNotificationsSeen() { notificationsSeen = true }
    func markDisplayNameSeen() { displayNameSeen = true }
    /// Reset onboarding flags when the user signs out; they're per-account.
    func resetForSignOut() {
        discogsTokenSeen = false
        notificationsSeen = false
        displayNameSeen = false
    }
}
