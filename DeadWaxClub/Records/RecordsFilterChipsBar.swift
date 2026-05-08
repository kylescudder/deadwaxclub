import SwiftUI

/// Horizontal scroller of active filter chips. Tapping the close icon clears
/// that facet of the filter. Used by the Records tab and any record picker
/// that adopts `RecordsFilter` (e.g. add-to-list).
struct RecordsFilterChipsBar: View {
    @Binding var filter: RecordsFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                if filter.statuses == [.owned] {
                    chip("Owned only") { filter.statuses = [] }
                } else if filter.statuses == [.wishlist] {
                    chip("Wishlist only") { filter.statuses = [] }
                }
                if let range = filter.yearRange {
                    chip(yearChipLabel(for: range)) {
                        filter.yearRange = nil
                    }
                }
                if let cw = filter.colourwayContains, !cw.isEmpty {
                    chip("Colour: \(cw)") { filter.colourwayContains = nil }
                }
                if filter.hasPriceOnly {
                    chip("With est. value") { filter.hasPriceOnly = false }
                }
                if filter.hasNoPriceOnly {
                    chip("Missing price") { filter.hasNoPriceOnly = false }
                }
            }
        }
    }

    private func yearChipLabel(for range: ClosedRange<Int>) -> String {
        switch (range.lowerBound, range.upperBound) {
        case (.min, .max):       return "Any year"
        case (.min, let upper):  return "Up to \(upper)"
        case (let lower, .max):  return "\(lower)+"
        case (let lower, let upper) where lower == upper: return "Year \(lower)"
        case (let lower, let upper): return "Year \(lower)–\(upper)"
        }
    }

    private func chip(_ text: String, onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.caption)
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Colors.surface)
        .clipShape(Capsule())
    }
}
