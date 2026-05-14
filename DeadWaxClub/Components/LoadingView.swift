import SwiftUI

struct LoadingView: View {
    var message: String? = nil

    /// Name of the gif (without extension) in the app bundle. Drop the file
    /// into `DeadWaxClub/Resources/` and it'll be picked up automatically;
    /// when the gif isn't present we fall back to the system spinner.
    private static let loadingGifName = "loading"

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            if GIFView.exists(named: LoadingView.loadingGifName) {
                GIFView(name: LoadingView.loadingGifName)
                    .frame(width: 96, height: 96)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
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
