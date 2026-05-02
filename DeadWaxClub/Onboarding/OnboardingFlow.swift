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

    @Published var current: OnboardingStep?

    /// Decide what to show right now given current profile + token state.
    /// Called whenever the user signs in or completes a step.
    func reconcile(profileDisplayName: String?, hasDiscogsToken: Bool, notificationsAuthorized: Bool) {
        let displayNameMissing = (profileDisplayName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        if displayNameMissing {
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
}
