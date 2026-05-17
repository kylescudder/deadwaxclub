import SwiftUI

struct LoadingView: View {
    var message: String? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            LottieAnimationView(name: "dwc_logo_spinner.lottie")
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
