import SwiftUI

struct RecordDetailView: View {
    let record: VinylRecord

    @EnvironmentObject private var services: AppServices
    @State private var showLogPriceSheet = false
    @State private var showStatusMenu = false
    @State private var currentRecord: VinylRecord

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
                        Task { await toggleStatus() }
                    } label: {
                        Label(
                            currentRecord.status == .owned ? "Move to wishlist" : "Move to owned",
                            systemImage: currentRecord.status == .owned ? "heart" : "checkmark.circle"
                        )
                    }
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

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            PrimaryButton(title: "Log price", systemImage: "tag") {
                showLogPriceSheet = true
            }
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
