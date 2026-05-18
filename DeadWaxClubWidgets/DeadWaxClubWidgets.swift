import SwiftUI
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
    let snapshot: WishlistPriceAlertSnapshot?
}

private struct WishlistPriceProvider: TimelineProvider {
    func placeholder(in context: Context) -> WishlistPriceEntry {
        WishlistPriceEntry(
            date: Date(),
            snapshot: WishlistPriceAlertSnapshot(
                id: "preview",
                recordID: "preview",
                title: "Blue Train - John Coltrane",
                body: "New low: £18.00 (was £24.00) at Flashback",
                priceCents: 1800,
                currency: "GBP",
                shopName: "Flashback",
                createdAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WishlistPriceEntry) -> Void) {
        completion(WishlistPriceEntry(date: Date(), snapshot: WidgetSnapshotStore.wishlistPriceAlert()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WishlistPriceEntry>) -> Void) {
        completion(Timeline(entries: [WishlistPriceEntry(date: Date(), snapshot: WidgetSnapshotStore.wishlistPriceAlert())], policy: .never))
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
            if let snapshot = entry.snapshot {
                Link(destination: recordURL(snapshot.recordID)) {
                    alertLayout(snapshot)
                }
            } else {
                emptyLayout
            }
        }
        .widgetContainerStyle()
    }

    private func alertLayout(_ snapshot: WishlistPriceAlertSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.forward.circle.fill")
                Text("Wishlist low")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.72))

            Text(snapshot.title)
                .font(family == .systemSmall ? .headline : .title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(family == .systemSmall ? 2 : 1)

            Text(snapshot.body)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(family == .systemSmall ? 3 : 2)

            Spacer(minLength: 0)

            Text(snapshot.createdAt, style: .relative)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
        padding(16)
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
    }
}

@main
struct DeadWaxClubWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DeadWaxClubQuickActionsWidget()
        DeadWaxClubWishlistPriceWidget()
    }
}
