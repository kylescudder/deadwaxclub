import SwiftUI

struct ScanResultSheet: View {
    let lookup: DiscogsLookup
    let barcode: String
    let existing: VinylRecord?

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var status: RecordStatus = .wishlist
    @State private var amount: String = ""
    @State private var currency: String = Preferences.currency
    @State private var shopName: String = ""
    @State private var isSaving = false
    @State private var saveNotice: ScanSaveNotice?
    @State private var saveCount = 0
    @State private var errorCount = 0
    @State private var selectionCount = 0
    @State private var celebrationCount = 0

    init(lookup: DiscogsLookup, barcode: String, existing: VinylRecord?, initialStatus: RecordStatus) {
        self.lookup = lookup
        self.barcode = barcode
        self.existing = existing
        _status = State(initialValue: existing?.status ?? initialStatus)
    }

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
                            Text("Status").footnoteSecondary()
                            Picker("", selection: $status) {
                                ForEach(RecordStatus.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Log shop price (optional)")
                                .footnoteSecondary()
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
            .sensoryFeedback(.success, trigger: saveCount)
            .sensoryFeedback(.error, trigger: errorCount)
            .sensoryFeedback(.selection, trigger: selectionCount)
            .overlay {
                ConfettiBurst(trigger: celebrationCount)
            }
            .onChange(of: status) { _, _ in selectionCount += 1 }
            .alert(item: $saveNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK")) {
                        if notice.dismissAfterAcknowledgement {
                            dismiss()
                        }
                    }
                )
            }
        }
    }

    private func save() async {
        guard let ownerID = services.auth.currentUserID?.lowerUUID else { return }
        // Existing record stays in its Collection; a fresh scan lands in the user's primary.
        let resolvedCollectionID: String? = existing?.collectionID
            ?? services.profile.profile?.primaryCollectionID
        guard let collectionID = resolvedCollectionID else { return }
        isSaving = true
        defer { isSaving = false }

        let now = Date()
        if existing == nil,
           let duplicate = await services.records.findDuplicate(
            title: lookup.title,
            artist: lookup.artist,
            displayYear: lookup.albumYear ?? lookup.year,
            colourway: lookup.colourway,
            discogsReleaseID: lookup.releaseID,
            barcode: lookup.barcode ?? barcode,
            userID: ownerID,
            collectionID: collectionID
           ) {
            let destinationName = collectionName(collectionID)
            if duplicate.status == .wishlist && status == .owned {
                await services.records.updateStatus(recordID: duplicate.id, status: .owned)
                await addPriceIfNeeded(recordID: duplicate.id, collectionID: duplicate.collectionID, ownerID: ownerID, scannedAt: now)
                saveNotice = ScanSaveNotice(
                    title: "Wishlist item purchased",
                    message: "You have purchased something from your wishlist. We moved it to Owned in \(destinationName).",
                    dismissAfterAcknowledgement: true
                )
                celebrationCount += 1
                saveCount += 1
            } else if duplicate.status == .owned {
                saveNotice = ScanSaveNotice(
                    title: "You already own this record",
                    message: "This record is already in \(destinationName)."
                )
                errorCount += 1
            } else {
                saveNotice = ScanSaveNotice(
                    title: "Already on your wishlist",
                    message: "This record is already on your wishlist in \(destinationName)."
                )
                errorCount += 1
            }
            return
        }

        let recordID = existing?.id ?? UUID().lowerUUID
        let record = VinylRecord(
            id: recordID,
            collectionID: collectionID,
            status: status,
            title: lookup.title,
            artist: lookup.artist,
            year: lookup.year,
            albumYear: lookup.albumYear,
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
            await addPriceIfNeeded(recordID: recordID, collectionID: collectionID, ownerID: ownerID, scannedAt: now)
        }
        saveCount += 1
        dismiss()
    }

    private func addPriceIfNeeded(recordID: String, collectionID: String, ownerID: String, scannedAt: Date) async {
        guard let cents = priceCents else { return }
        let entry = PriceEntry(
            id: UUID().lowerUUID,
            recordID: recordID,
            ownerID: ownerID,
            collectionID: collectionID,
            priceCents: cents,
            currency: currency,
            shopName: shopName.isEmpty ? nil : shopName,
            scannedAt: scannedAt,
            createdAt: scannedAt
        )
        await services.prices.add(entry)
    }

    private var priceCents: Int? {
        let normalized = amount.replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, let value = Decimal(string: normalized) else { return nil }
        let cents = NSDecimalNumber(decimal: value * 100).intValue
        return cents > 0 ? cents : nil
    }

    private func collectionName(_ collectionID: String) -> String {
        services.collections.collections.first(where: { $0.id == collectionID })?.name ?? "this collection"
    }

    private static let commonCurrencies = ["GBP", "USD", "EUR", "CAD", "AUD", "JPY"]
}

private struct ScanSaveNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var dismissAfterAcknowledgement = false
}
