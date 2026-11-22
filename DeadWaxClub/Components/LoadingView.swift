import SwiftUI

/// Full-screen loading state. The animation comes from `Theme.loadingAnimation`
/// in the app's `Theme+App.swift`.
struct LoadingView: View {
    var message: String? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            LottieAnimationView(name: Theme.loadingAnimation)
                .frame(width: 96, height: 96)
                .fixedSize()

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
    }
}
