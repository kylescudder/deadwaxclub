import SwiftUI

struct RecordDetailView: View {
    let record: VinylRecord

    @EnvironmentObject private var services: AppServices
    @State private var showLogPriceSheet = false
    @State private var showStatusMenu = false
    @State private var currentRecord: VinylRecord
    @State private var showAddToListSheet = false
    @State private var showEditSheet = false
    @State private var editingPriceEntry: PriceEntry?

    init(record: VinylRecord) {
        self.record = record
        self._currentRecord = State(initialValue: record)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                CoverArtImage(record: currentRecord)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                    .padding(.horizontal, Theme.Spacing.lg)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(currentRecord.title)
                        .font(.title2.weight(.bold))
                    Text(currentRecord.artist)
                        .font(.title3)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .padding(.horizontal, Theme.Spacing.lg)

                detailsCard
                    .padding(.horizontal, Theme.Spacing.lg)

                priceCard
                    .padding(.horizontal, Theme.Spacing.lg)

                if !services.prices.entries.isEmpty {
                    priceLogCard
                        .padding(.horizontal, Theme.Spacing.lg)
                }

                actionRow
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.xxl)
            }
            .padding(.top, Theme.Spacing.lg)
        }
        .background(Theme.Colors.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showEditSheet = true
                    } label: { Label("Edit details", systemImage: "pencil") }
                    Button {
                        Task { await toggleStatus() }
                    } label: {
                        Label(
                            currentRecord.status == .owned ? "Move to wishlist" : "Move to owned",
                            systemImage: currentRecord.status == .owned ? "heart" : "checkmark.circle"
                        )
                    }
                    Button {
                        showAddToListSheet = true
                    } label: { Label("Add to list…", systemImage: "list.bullet.rectangle") }
                    Button(role: .destructive) {
                        Task { await services.records.softDelete(recordID: currentRecord.id) }
                    } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showLogPriceSheet) {
            LogPriceSheet(record: currentRecord)
        }
        .sheet(isPresented: $showEditSheet, onDismiss: refreshFromLocal) {
            NavigationStack {
                AddRecordView(initialStatus: currentRecord.status, existing: currentRecord)
            }
        }
        .sheet(item: $editingPriceEntry) { entry in
            LogPriceSheet(record: currentRecord, existing: entry)
        }
        .sheet(isPresented: $showAddToListSheet) {
            AddRecordToListsSheet(record: currentRecord)
        }
        .task {
            services.prices.startWatching(recordID: currentRecord.id)
            await services.coverArt.cacheIfNeeded(record: currentRecord) { newPath in
                Task { @MainActor in
                    self.currentRecord.coverArtStoragePath = newPath
                    await services.records.updateStoragePath(recordID: currentRecord.id, storagePath: newPath)
                }
            }
        }
    }

    private var detailsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                detailRow("Status", currentRecord.status.label)
                if let year = currentRecord.year {
                    detailRow("Year", String(year))
                }
                if let cw = currentRecord.colourway, !cw.isEmpty {
                    detailRow("Colour way", cw)
                }
                if let bc = currentRecord.barcode, !bc.isEmpty {
                    detailRow("Barcode", bc)
                }
                if let notes = currentRecord.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .padding(.top, Theme.Spacing.xs)
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.Colors.textSecondary)
            Spacer()
            Text(value).foregroundStyle(Theme.Colors.textPrimary)
        }
        .font(.callout)
    }

    private var priceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                priceSummaryRow

                Divider()

                HStack {
                    Text("Price history").font(.callout.weight(.semibold))
                    Spacer()
                    if let lowest = services.prices.entries.min(by: { $0.priceCents < $1.priceCents }) {
                        Text("Low: \(lowest.formattedPrice)")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                PriceChartView(entries: services.prices.entries)
                    .frame(height: 180)
            }
        }
    }

    /// Header row that draws a clear visual line between
    ///   "you paid ${latest user-recorded price}"
    /// and
    ///   "Discogs estimate ${marketplace median}".
    private var priceSummaryRow: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text("You paid")
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.Colors.accent)
                }
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)

                if let latest = services.prices.entries.max(by: { $0.scannedAt < $1.scannedAt }) {
                    Text(latest.formattedPrice)
                        .font(.title3.weight(.semibold))
                } else {
                    Text("—")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text("Discogs estimate")
                } icon: {
                    Image(systemName: "globe").foregroundStyle(Theme.Colors.textSecondary)
                }
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)

                if let cents = currentRecord.estimatedPriceCents,
                   let currency = currentRecord.estimatedPriceCurrency {
                    Text(formatCents(cents, currency: currency))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.green)
                    if let updated = currentRecord.estimatedPriceUpdatedAt {
                        Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                } else {
                    Text("—")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatCents(_ cents: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSDecimalNumber(value: Double(cents) / 100.0)) ?? "\(cents)"
    }

    private var priceLogCard: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Logged prices")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.top, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.sm)

                ForEach(Array(sortedEntries.enumerated()), id: \.element.id) { idx, entry in
                    Button {
                        editingPriceEntry = entry
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.formattedPrice)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                HStack(spacing: 6) {
                                    Text(entry.scannedAt.formatted(date: .abbreviated, time: .omitted))
                                    if let shop = entry.shopName, !shop.isEmpty {
                                        Text("·")
                                        Text(shop)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "pencil")
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .font(.caption)
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if idx < sortedEntries.count - 1 {
                        Divider().padding(.leading, Theme.Spacing.lg)
                    }
                }
                .padding(.bottom, Theme.Spacing.sm)
            }
        }
    }

    private var sortedEntries: [PriceEntry] {
        services.prices.entries.sorted { $0.scannedAt > $1.scannedAt }
    }

    private func refreshFromLocal() {
        Task { @MainActor in
            // After Edit Details closes, the records repo's watch loop will
            // already have published the latest row; just pull it from there.
            if let latest = services.records.records.first(where: { $0.id == currentRecord.id }) {
                currentRecord = latest
            }
        }
    }

    private var actionRow: some View {
        VStack(spacing: Theme.Spacing.sm) {
            PrimaryButton(title: "Log price", systemImage: "tag") {
                showLogPriceSheet = true
            }
            if currentRecord.discogsReleaseID != nil {
                SecondaryButton(title: "Refresh Discogs estimate", systemImage: "arrow.clockwise") {
                    Task { await refreshEstimate() }
                }
            }
        }
    }

    private func refreshEstimate() async {
        guard let releaseID = currentRecord.discogsReleaseID else { return }
        do {
            if let estimate = try await services.discogs.marketplaceStats(releaseID: releaseID) {
                await services.records.updateEstimate(
                    recordID: currentRecord.id,
                    cents: estimate.cents,
                    currency: estimate.currency
                )
                currentRecord.estimatedPriceCents = estimate.cents
                currentRecord.estimatedPriceCurrency = estimate.currency
                currentRecord.estimatedPriceUpdatedAt = Date()
                Haptics.success()
            }
        } catch {
            Log.error(error, category: "records.refreshEstimate")
            Haptics.error()
        }
    }

    private func toggleStatus() async {
        var updated = currentRecord
        updated.status = currentRecord.status == .owned ? .wishlist : .owned
        updated.updatedAt = Date()
        currentRecord = updated
        await services.records.upsert(updated)
    }
}

extension PriceEntry {
    var formattedPrice: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: priceMajor as NSDecimalNumber) ?? "\(priceMajor) \(currency)"
    }
}
