import SwiftUI

/// A grouped surface for a block of content. This file is identical in every
/// app; its padding, corner radius, width and border come from
/// `Theme.CardStyle` in `Theme+App.swift`.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.CardStyle.padding
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.CardStyle.cornerRadius, style: .continuous)
        width(content().padding(padding))
            .background(Theme.Colors.surface)
            .clipShape(shape)
            .overlay {
                if Theme.CardStyle.showsBorder {
                    shape.stroke(Theme.Colors.separator)
                }
            }
    }

    @ViewBuilder
    private func width(_ view: some View) -> some View {
        if Theme.CardStyle.fillsWidth {
            view.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            view
        }
    }
}
