import SwiftUI

struct DisplayNameOnboardingView: View {
    let onDone: (String) -> Void

    @State private var name = ""
    @State private var isSaving = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.Colors.accent)

            VStack(spacing: Theme.Spacing.sm) {
                Text("What should we call you?")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Shows up on lists you share with others.")
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            TextField("Your name", text: $name)
                .textContentType(.name)
                .padding()
                .background(Theme.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .focused($focused)

            Spacer()

            PrimaryButton(title: "Continue", isLoading: isSaving) {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                isSaving = true
                onDone(trimmed)
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
        }
        .padding(Theme.Spacing.xl)
        .interactiveDismissDisabled()
        .onAppear { focused = true }
    }
}
