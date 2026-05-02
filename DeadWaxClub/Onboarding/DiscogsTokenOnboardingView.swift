import SwiftUI

struct DiscogsTokenOnboardingView: View {
    let onDone: () -> Void
    let onSkip: () -> Void

    @EnvironmentObject private var services: AppServices
    @State private var token = ""
    @State private var saved = false

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.Colors.accent)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Add a Discogs token")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("We use Discogs to look up records when you scan a barcode and to fetch cover art and estimated value.")
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: Theme.Spacing.sm) {
                Link(destination: URL(string: "https://www.discogs.com/settings/developers")!) {
                    Label("Generate a personal token", systemImage: "arrow.up.right.square")
                        .font(.callout)
                }
                SecureField("Paste your token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background(Theme.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }

            Spacer()

            VStack(spacing: Theme.Spacing.sm) {
                PrimaryButton(title: "Save token") {
                    services.discogs.setToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
                    saved = true
                    onDone()
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Skip for now", action: onSkip)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(Theme.Spacing.xl)
    }
}
