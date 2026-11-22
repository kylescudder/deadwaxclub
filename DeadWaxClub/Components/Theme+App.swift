import SwiftUI

/// Deadwax-only design tokens layered on the shared `Theme`.
extension Theme {
    /// Lottie animation shown by `LoadingView`.
    static let loadingAnimation = "dwc_logo_spinner.lottie"

    /// `Card`: roomy, full width, no border.
    enum CardStyle {
        static let padding = Theme.Spacing.lg
        static let cornerRadius = Theme.Radius.lg
        static let fillsWidth = true
        static let showsBorder = false
    }
}
