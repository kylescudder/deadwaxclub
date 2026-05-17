import SwiftUI
import Charts
import Combine
import PowerSync

struct StatsView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var repo: StatsRepositoryHolder = StatsRepositoryHolder()
    /// nil = aggregate across every Collection the user belongs to.
    @State private var selectedCollectionID: String?
    @State private var refreshCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if services.collections.collections.count > 1 {
                    scopePicker
                }

                if repo.repo?.isLoading == true {
                    LoadingView().frame(height: 240)
                } else if let stats = repo.repo?.stats {
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
            refreshCount += 1
            await refresh()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: refreshCount)
        .task {
            repo.attach(database: services.sync.database)
            await refresh()
        }
        .task(id: selectedCollectionID) { await refresh() }
    }

    @ViewBuilder
    private var scopePicker: some View {
        Picker("Scope", selection: $selectedCollectionID) {
            Text("All my Collections").tag(String?.none)
            ForEach(services.collections.collections) { c in
                Text(c.name).tag(Optional(c.id))
            }
        }
        .pickerStyle(.menu)
    }

    private func refresh() async {
        guard let userID = services.auth.currentUserID?.lowerUUID else { return }
        let scope: StatsScope = selectedCollectionID
            .map { .singleCollection(collectionID: $0) }
            ?? .allMyCollections(userID: userID)

        await repo.repo?.refresh(scope: scope)
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
            Text(label).footnoteSecondary()
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
                            .captionSecondary()
                        Text(CurrencyFormatter.formatCents(stats.totalSpentCents, code: stats.currency))
                            .font(.title2.weight(.semibold))
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Estimated value")
                            .captionSecondary()
                        Text(CurrencyFormatter.formatCents(stats.estimatedValueCents, code: stats.currency))
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
                            Text(entry.artist).captionSecondary().lineLimit(1)
                        }
                        Spacer()
                        Text(CurrencyFormatter.formatCents(entry.paidCents, code: entry.currency))
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
                            Text(entry.artist).captionSecondary().lineLimit(1)
                        }
                        Spacer()
                        Text(CurrencyFormatter.formatCents(entry.lowestCents, code: entry.currency))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

}

@MainActor
final class StatsRepositoryHolder: ObservableObject {
    @Published var repo: StatsRepository?
    // Re-broadcast the inner repo's objectWillChange so SwiftUI re-renders
    // when stats/isLoading change. Without this, the view only updates on
    // the initial `repo` assignment and gets stuck on whatever it rendered
    // mid-refresh — which on a fresh sign-in is the loading spinner.
    private var cancellable: AnyCancellable?

    func attach(database: PowerSyncDatabaseProtocol) {
        guard repo == nil else { return }
        let r = StatsRepository(database: database)
        repo = r
        cancellable = r.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }
}
