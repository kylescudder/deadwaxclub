import SwiftUI
import Charts
import PowerSync

struct StatsView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var repo: StatsRepositoryHolder = StatsRepositoryHolder()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if let stats = repo.repo?.stats {
                    summaryCard(stats: stats)
                    valueCard(stats: stats)
                    if !stats.byDecade.isEmpty {
                        decadesCard(buckets: stats.byDecade)
                    }
                    if !stats.byColourway.isEmpty {
                        colourwaysCard(buckets: stats.byColourway)
                    }
                    if !stats.topPaid.isEmpty {
                        topPaidCard(entries: stats.topPaid)
                    }
                    if !stats.lowestSeen.isEmpty {
                        lowestSeenCard(entries: stats.lowestSeen)
                    }
                } else if repo.repo?.isLoading == true {
                    LoadingView().frame(height: 240)
                } else {
                    EmptyState(
                        systemImage: "chart.bar",
                        title: "No data yet",
                        message: "Add records and prices to your collection to see stats here."
                    )
                    .frame(height: 240)
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.Colors.background)
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            Haptics.tap()
            await refresh()
        }
        .task {
            repo.attach(database: services.sync.database)
            await refresh()
        }
    }

    private func refresh() async {
        guard let userID = services.auth.currentUserID?.uuidString else { return }
        await repo.repo?.refresh(ownerID: userID)
    }

    private func summaryCard(stats: CollectionStats) -> some View {
        Card {
            HStack(spacing: Theme.Spacing.lg) {
                metric("Owned", value: "\(stats.ownedCount)")
                Divider()
                metric("Wishlist", value: "\(stats.wishlistCount)")
            }
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title.weight(.bold))
            Text(label).font(.footnote).foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueCard(stats: CollectionStats) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Collection value").font(.callout.weight(.semibold))
                HStack {
                    VStack(alignment: .leading) {
                        Text("You've spent")
                            .font(.caption).foregroundStyle(Theme.Colors.textSecondary)
                        Text(formatCents(stats.totalSpentCents, currency: stats.currency))
                            .font(.title2.weight(.semibold))
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Estimated value")
                            .font(.caption).foregroundStyle(Theme.Colors.textSecondary)
                        Text(formatCents(stats.estimatedValueCents, currency: stats.currency))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    private func decadesCard(buckets: [DecadeBucket]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("By decade").font(.callout.weight(.semibold))
                Chart(buckets) { bucket in
                    BarMark(
                        x: .value("Decade", bucket.decade),
                        y: .value("Count", bucket.count)
                    )
                    .foregroundStyle(Theme.Colors.accent)
                }
                .frame(height: 180)
            }
        }
    }

    private func colourwaysCard(buckets: [ColourwayBucket]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Top colour ways").font(.callout.weight(.semibold))
                ForEach(buckets) { bucket in
                    HStack {
                        Text(bucket.colourway).lineLimit(1)
                        Spacer()
                        Text("\(bucket.count)")
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func topPaidCard(entries: [PaidEntry]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Most expensive").font(.callout.weight(.semibold))
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.title).font(.callout).lineLimit(1)
                            Text(entry.artist).font(.caption).foregroundStyle(Theme.Colors.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        Text(formatCents(entry.paidCents, currency: entry.currency))
                            .font(.callout.weight(.semibold))
                    }
                }
            }
        }
    }

    private func lowestSeenCard(entries: [LowestEntry]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Wishlist lows").font(.callout.weight(.semibold))
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.title).font(.callout).lineLimit(1)
                            Text(entry.artist).font(.caption).foregroundStyle(Theme.Colors.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        Text(formatCents(entry.lowestCents, currency: entry.currency))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    private func formatCents(_ cents: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSDecimalNumber(value: Double(cents) / 100.0)) ?? "\(cents)"
    }
}

@MainActor
final class StatsRepositoryHolder: ObservableObject {
    @Published var repo: StatsRepository?

    func attach(database: PowerSyncDatabaseProtocol) {
        if repo == nil {
            repo = StatsRepository(database: database)
        }
    }
}
