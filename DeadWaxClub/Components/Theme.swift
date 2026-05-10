import SwiftUI

/// Small native iOS design system. Uses system semantic colors so dark mode
/// works automatically. Spacing and radius scales kept simple to mirror what
/// SwiftUI defaults expect.
enum Theme {
    enum Colors {
        static let accent = Color.accentColor
        static let background = Color(.systemGroupedBackground)
        static let surface = Color(.secondarySystemGroupedBackground)
        static let surfaceElevated = Color(.tertiarySystemGroupedBackground)
        static let separator = Color(.separator)
        static let textPrimary = Color(.label)
        static let textSecondary = Color(.secondaryLabel)
        static let textTertiary = Color(.tertiaryLabel)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }
}

extension View {
    /// `.font(.caption)` + `Theme.Colors.textSecondary`. Use everywhere a small
    /// dimmed annotation appears so the pairing stays consistent across screens.
    func captionSecondary() -> some View {
        font(.caption).foregroundStyle(Theme.Colors.textSecondary)
    }

    /// `.font(.footnote)` + `Theme.Colors.textSecondary`. Same deal as
    /// `captionSecondary` but one font step larger.
    func footnoteSecondary() -> some View {
        font(.footnote).foregroundStyle(Theme.Colors.textSecondary)
    }
}
