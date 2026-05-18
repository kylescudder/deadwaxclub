import SwiftUI

struct EmptyState: View {
    let systemImage: String
    var imageName: String? = nil
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var secondaryActionTitle: String? = nil
    var secondaryActionSystemImage: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ZStack {
                if let imageName {
                    ZStack {
                        Image(imageName)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 112, height: 112)
                            .scaleEffect(1.23)
                    }
                    .frame(width: 112, height: 112)
                    .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Theme.Colors.accent.opacity(0.12))
                        .frame(width: 112, height: 112)
                    Image(systemName: systemImage)
                        .font(.system(size: 48, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            VStack(spacing: Theme.Spacing.sm) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                if !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            if actionTitle != nil || secondaryActionTitle != nil {
                VStack(spacing: Theme.Spacing.sm) {
                    if let actionTitle, let action {
                        PrimaryButton(title: actionTitle, fullWidth: false, action: action)
                    }
                    if let secondaryActionTitle, let secondaryAction {
                        SecondaryButton(
                            title: secondaryActionTitle,
                            systemImage: secondaryActionSystemImage,
                            fullWidth: false,
                            action: secondaryAction
                        )
                    }
                }
                .padding(.top, Theme.Spacing.sm)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
