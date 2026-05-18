import SwiftUI

struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading: Bool = false
    var isDestructive: Bool = false
    var fullWidth: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if isLoading {
                    ProgressView().tint(foregroundColor)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: 50)
            .padding(.horizontal, Theme.Spacing.lg)
            .background(isDestructive ? Color.red : Theme.Colors.accent)
            .foregroundStyle(foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        .disabled(isLoading)
    }

    private var foregroundColor: Color {
        isDestructive ? .white : .black
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var assetImage: String? = nil
    var iconTextSpacing: CGFloat = Theme.Spacing.sm
    var titleFont: Font = .body.weight(.medium)
    var fullWidth: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: iconTextSpacing) {
                if let assetImage {
                    Image(assetImage)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).font(titleFont)
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: 50)
            .padding(.horizontal, Theme.Spacing.lg)
            .background(Theme.Colors.surface)
            .foregroundStyle(Theme.Colors.textPrimary)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.separator, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }
}
