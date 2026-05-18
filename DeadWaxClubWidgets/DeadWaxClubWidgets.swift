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

@main
struct DeadWaxClubWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DeadWaxClubQuickActionsWidget()
    }
}
