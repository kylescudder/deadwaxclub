import SwiftUI

struct ScanResultSheet: View {
    let lookup: DiscogsLookup
    let barcode: String
    let existing: VinylRecord?

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var status: RecordStatus = .wishlist
    @State private var amount: String = ""
    @State private var currency: String = Locale.current.currency?.identifier ?? "GBP"
    @State private var shopName: String = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    if let urlString = lookup.coverArtURL, let url = URL(string: urlString) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            default:
                                Theme.Colors.surface
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    }

                    VStack(spacing: Theme.Spacing.xs) {
                        Text(lookup.title).font(.title3.weight(.semibold))
                        Text(lookup.artist).foregroundStyle(Theme.Colors.textSecondary)
                        if let cw = lookup.colourway {
                            Text(cw).font(.footnote).foregroundStyle(Theme.Colors.textTertiary)
                        }
                    }

                    if existing != nil {
                        Card {
                            Label("Already in your collection — logging another price will be added to history.",
                                  systemImage: "info.circle")
                                .font(.footnote)
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Status").font(.footnote).foregroundStyle(Theme.Colors.textSecondary)
                            Picker("", selection: $status) {
                                ForEach(RecordStatus.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Log shop price (optional)")
                                .font(.footnote)
                                .foregroundStyle(Theme.Colors.textSecondary)
                            HStack {
                                TextField("0.00", text: $amount)
                                    .keyboardType(.decimalPad)
                                Picker("", selection: $currency) {
                                    ForEach(Self.commonCurrencies, id: \.self) { Text($0).tag($0) }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }
                            TextField("Shop", text: $shopName)
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.Colors.background)
            .navigationTitle("Scanned")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(isSaving)
                }
            }
        }
    }

    private func save() async {
        guard let ownerID = services.auth.currentUserID?.uuidString.lowercased() else { return }
        // Existing record stays in its Collection; a fresh scan lands in the user's primary.
        let resolvedCollectionID: String? = existing?.collectionID
            ?? services.profile.profile?.primaryCollectionID
        guard let collectionID = resolvedCollectionID else { return }
        isSaving = true
        defer { isSaving = false }

        let now = Date()
        let recordID = existing?.id ?? UUID().uuidString.lowercased()
        let record = VinylRecord(
            id: recordID,
            collectionID: collectionID,
            status: status,
            title: lookup.title,
            artist: lookup.artist,
            year: lookup.year,
            colourway: lookup.colourway,
            coverArtSourceURL: lookup.coverArtURL,
            coverArtStoragePath: existing?.coverArtStoragePath,
            discogsReleaseID: lookup.releaseID,
            barcode: lookup.barcode ?? barcode,
            notes: existing?.notes,
            estimatedPriceCents: lookup.estimatedPriceCents ?? existing?.estimatedPriceCents,
            estimatedPriceCurrency: lookup.estimatedCurrency ?? existing?.estimatedPriceCurrency,
            estimatedPriceUpdatedAt: lookup.estimatedPriceCents != nil ? now : existing?.estimatedPriceUpdatedAt,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            deletedAt: nil
        )
        await services.records.upsert(record)
        if !lookup.imageURLs.isEmpty {
            await services.ingestDiscogsImages(
                recordID: recordID,
                collectionID: collectionID,
                sourceURLs: lookup.imageURLs
            )
        }

        if let cents = priceCents {
            let entry = PriceEntry(
                id: UUID().uuidString.lowercased(),
                recordID: recordID,
                ownerID: ownerID,
                collectionID: collectionID,
                priceCents: cents,
                currency: currency,
                shopName: shopName.isEmpty ? nil : shopName,
                scannedAt: now,
                createdAt: now
            )
            await services.prices.add(entry)
        }
        Haptics.success()
        dismiss()
    }

    private var priceCents: Int? {
        let normalized = amount.replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, let value = Decimal(string: normalized) else { return nil }
        let cents = NSDecimalNumber(decimal: value * 100).intValue
        return cents > 0 ? cents : nil
    }

    private static let commonCurrencies = ["GBP", "USD", "EUR", "CAD", "AUD", "JPY"]
}
