import SwiftUI

struct RecordRowView: View {
    let record: VinylRecord

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            CoverArtImage(record: record)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(record.artist)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                if let cw = record.colourway {
                    Text(cw)
                        .font(.caption2)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}
