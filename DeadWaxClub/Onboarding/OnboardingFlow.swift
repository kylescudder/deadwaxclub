import Foundation
import SwiftUI

/// The set of one-time onboarding sheets a newly signed-in user might see,
/// in display order. Empty array means everything's already done.
///
/// Display name is intentionally NOT an onboarding step — Apple/Google supply
/// it on first sign-in via `raw_user_meta_data`, the email/password form asks
/// for it inline, and worst case the user can set it from Settings later.
enum OnboardingStep: Identifiable, Hashable {
    case discogsToken
    case enableNotifications

    var id: Self { self }
}

@MainActor
final class OnboardingCoordinator: ObservableObject {
    @AppStorage("onboarding.discogsTokenSeen") private var discogsTokenSeen: Bool = false
    @AppStorage("onboarding.notificationsSeen") private var notificationsSeen: Bool = false

    @Published var current: OnboardingStep?

    /// Decide what to show right now given current profile + token state.
    /// Called whenever the user signs in or completes a step.
    /// `profileLoaded` is the gate that prevents flashing a sheet before the
    /// local DB has had a chance to surface the row.
    func reconcile(profileLoaded: Bool, profileDisplayName: String?, hasDiscogsToken: Bool, notificationsAuthorized: Bool) {
        guard profileLoaded else { return }
        _ = profileDisplayName // kept in the signature for callers; no longer drives onboarding

        if !discogsTokenSeen && !hasDiscogsToken {
            current = .discogsToken
        } else if !notificationsSeen && !notificationsAuthorized {
            current = .enableNotifications
        } else {
            current = nil
        }
    }

    func markDiscogsTokenSeen() { discogsTokenSeen = true }
    func markNotificationsSeen() { notificationsSeen = true }
    /// Reset onboarding flags when the user signs out; they're per-account.
    func resetForSignOut() {
        discogsTokenSeen = false
        notificationsSeen = false
    }
}
