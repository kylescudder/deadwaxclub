import SwiftUI
import UIKit
import WidgetKit

private struct QuickActionsEntry: TimelineEntry {
    let date: Date
}

private struct QuickActionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickActionsEntry {
        QuickActionsEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickActionsEntry) -> Void) {
        completion(QuickActionsEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickActionsEntry>) -> Void) {
        completion(Timeline(entries: [QuickActionsEntry(date: Date())], policy: .never))
    }
}

private struct WishlistPriceEntry: TimelineEntry {
    let date: Date
    let snapshots: [WishlistPriceAlertSnapshot]

    var latest: WishlistPriceAlertSnapshot? { snapshots.first }
}

private struct WishlistPriceProvider: TimelineProvider {
    func placeholder(in context: Context) -> WishlistPriceEntry {
        WishlistPriceEntry(
            date: Date(),
            snapshots: [
                WishlistPriceAlertSnapshot(
                    id: "preview",
                    recordID: "preview",
                    title: "Blue Train - John Coltrane",
                    body: "New low: £18.00 (was £24.00) at Flashback",
                    priceCents: 1800,
                    currency: "GBP",
                    shopName: "Flashback",
                    coverArtFileName: nil,
                    createdAt: Date()
                )
            ]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WishlistPriceEntry) -> Void) {
        completion(WishlistPriceEntry(date: Date(), snapshots: WidgetSnapshotStore.wishlistPriceAlerts()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WishlistPriceEntry>) -> Void) {
        completion(Timeline(entries: [WishlistPriceEntry(date: Date(), snapshots: WidgetSnapshotStore.wishlistPriceAlerts())], policy: .never))
    }
}

private enum QuickAction: String, CaseIterable, Identifiable {
    case scanBarcode
    case addRecord
    case logPrice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scanBarcode: "Scan"
        case .addRecord: "Add"
        case .logPrice: "Log Price"
        }
    }

    var subtitle: String {
        switch self {
        case .scanBarcode: "Barcode"
        case .addRecord: "Record"
        case .logPrice: "Sale"
        }
    }

    var systemImage: String {
        switch self {
        case .scanBarcode: "barcode.viewfinder"
        case .addRecord: "plus.circle.fill"
        case .logPrice: "tag.fill"
        }
    }

    var url: URL {
        URL(string: "deadwaxclub://shortcut/\(rawValue)")!
    }
}

private struct DeadWaxClubQuickActionsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickActionsEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallLayout
        default:
            expandedLayout
        }
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Link(destination: QuickAction.scanBarcode.url) {
                Label("Scan barcode", systemImage: QuickAction.scanBarcode.systemImage)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .widgetContainerStyle()
    }

    private var expandedLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            HStack(spacing: 10) {
                ForEach(QuickAction.allCases) { action in
                    Link(destination: action.url) {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: action.systemImage)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(action.title)
                                    .font(.headline)
                                Text(action.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.68))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
                        .padding(12)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 18))
                    }
                }
            }
        }
        .widgetContainerStyle()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Deadwax Club")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text("Vinyl shortcuts")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
        }
    }
}

private struct DeadWaxClubWishlistPriceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WishlistPriceEntry

    var body: some View {
        Group {
            if !entry.snapshots.isEmpty {
                if family == .systemSmall, let snapshot = entry.latest {
                    Link(destination: recordURL(snapshot.recordID)) {
                        compactAlertLayout(snapshot)
                    }
                } else if let snapshot = entry.latest {
                    Link(destination: recordURL(snapshot.recordID)) {
                        alertLayout(snapshot)
                    }
                }
            } else {
                emptyLayout
            }
        }
        .widgetContainerStyle()
    }

    private func compactAlertLayout(_ snapshot: WishlistPriceAlertSnapshot) -> some View {
        let titleParts = splitTitle(snapshot.title)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.forward.circle.fill")
                Text("Wishlist low")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.72))

            Text(titleParts.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let artist = titleParts.artist {
                Text(artist)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
            }

            Text(priceText(for: snapshot))
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Text(relativeAge(from: snapshot.createdAt))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func alertLayout(_ snapshot: WishlistPriceAlertSnapshot) -> some View {
        let titleParts = splitTitle(snapshot.title)

        return HStack(alignment: .center, spacing: 14) {
            coverThumbnail(snapshot, size: 88)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.forward.circle.fill")
                    Text("Wishlist low")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))

                Text(titleParts.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if let artist = titleParts.artist {
                    Text(artist)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.76))
                        .lineLimit(1)
                }

                Text(snapshot.body)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)

                Text(relativeAge(from: snapshot.createdAt))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .padding(.top, 3)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func coverThumbnail(_ snapshot: WishlistPriceAlertSnapshot, size: CGFloat) -> some View {
        if let image = coverImage(snapshot) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.26), radius: 10, x: 0, y: 6)
        } else {
            RoundedRectangle(cornerRadius: 16)
                .fill(.white.opacity(0.12))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "record.circle.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
        }
    }

    private func coverImage(_ snapshot: WishlistPriceAlertSnapshot) -> Image? {
        guard let fileName = snapshot.coverArtFileName,
              let url = WidgetSnapshotStore.coverArtFileURL(fileName: fileName),
              let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: uiImage)
    }

    private func splitTitle(_ title: String) -> (name: String, artist: String?) {
        let cleaned = title.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        let separators = [" — ", " - "]
        for separator in separators where cleaned.contains(separator) {
            let parts = cleaned.components(separatedBy: separator)
            guard parts.count >= 2 else { continue }
            return (parts.dropFirst().joined(separator: separator), parts[0])
        }
        return (cleaned, nil)
    }

    private func relativeAge(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) secs" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr" }
        return "\(hours / 24)d"
    }

    private func priceText(for snapshot: WishlistPriceAlertSnapshot) -> String {
        if let priceCents = snapshot.priceCents, let currency = snapshot.currency {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
            return formatter.string(from: NSNumber(value: Double(priceCents) / 100)) ?? snapshot.body
        }

        if let price = snapshot.body.components(separatedBy: ": ").last, price != snapshot.body {
            return price
        }
        return snapshot.body
    }

    private var emptyLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "heart.text.square.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text("Wishlist lows")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text("New lowest prices for wishlist records will appear here.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func recordURL(_ recordID: String) -> URL {
        URL(string: "deadwaxclub://record/\(recordID)") ?? URL(string: "deadwaxclub://shortcut/logPrice")!
    }
}

private extension View {
    func widgetContainerStyle() -> some View {
        padding(12)
            .containerBackground(for: .widget) {
                LinearGradient(
                    colors: [Color(red: 0.08, green: 0.07, blue: 0.10), Color(red: 0.42, green: 0.14, blue: 0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
    }
}

struct DeadWaxClubQuickActionsWidget: Widget {
    let kind = "DeadWaxClubQuickActionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickActionsProvider()) { entry in
            DeadWaxClubQuickActionsWidgetView(entry: entry)
        }
        .configurationDisplayName("Vinyl Shortcuts")
        .description("Quickly scan, add a record, or log a price in Deadwax Club.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct DeadWaxClubWishlistPriceWidget: Widget {
    let kind = WidgetSnapshotStore.priceAlertWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WishlistPriceProvider()) { entry in
            DeadWaxClubWishlistPriceWidgetView(entry: entry)
        }
        .configurationDisplayName("Wishlist Price Alerts")
        .description("Keep the latest new-low price for your wishlist on your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct DeadWaxClubWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DeadWaxClubQuickActionsWidget()
        DeadWaxClubWishlistPriceWidget()
    }
}
