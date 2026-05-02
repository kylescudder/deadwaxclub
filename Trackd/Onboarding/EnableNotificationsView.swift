import SwiftUI
import UserNotifications

struct EnableNotificationsView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "bell.badge")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.Colors.accent)
            VStack(spacing: Theme.Spacing.sm) {
                Text("Get notified at the lowest price")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("We'll let you know when a record on your wishlist is logged at a new low — by you or anyone you share a list with.")
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: Theme.Spacing.sm) {
                PrimaryButton(title: "Turn on notifications") {
                    Task { await PushManager.shared.requestAuthorization(); onDone() }
                }
                Button("Maybe later", action: onDone)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(Theme.Spacing.xl)
    }
}
