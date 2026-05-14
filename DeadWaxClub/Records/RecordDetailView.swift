import SwiftUI
import PhotosUI

struct RecordDetailView: View {
    let record: VinylRecord

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var showLogPriceSheet = false
    @State private var showStatusMenu = false
    @State private var currentRecord: VinylRecord
    @State private var showAddToListSheet = false
    @State private var showEditSheet = false
    @State private var editingPriceEntry: PriceEntry?
    @State private var showDiscogsPicker = false
    @State private var showCameraPicker = false
    @State private var photoPickerSelection: PhotosPickerItem?
    @State private var imageUploadError: String?
    @State private var successCount = 0
    @State private var errorCount = 0
    @State private var isDismissing = false

    init(record: VinylRecord) {
        self.record = record
        self._currentRecord = State(initialValue: record)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                ZStack(alignment: .topTrailing) {
                    RecordImageCarousel(record: currentRecord)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                    addImageMenu
                        .padding(Theme.Spacing.sm)
                }
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
                    if writableMoveTargets.count > 0 {
                        Menu {
                            ForEach(writableMoveTargets) { target in
                                Button(target.name) {
                                    Task { await move(to: target.id) }
                                }
                            }
                        } label: {
                            Label("Move to Collection…", systemImage: "rectangle.stack")
                        }
                    }
                    Button(role: .destructive) {
                        Task { await deleteAndDismiss() }
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
        .sheet(isPresented: $showDiscogsPicker) {
            DiscogsPickerView(
                initialTitle: currentRecord.title,
                initialArtist: currentRecord.artist
            ) { lookup in
                Task { await applyDiscogsLookup(lookup) }
            }
        }
        .sheet(isPresented: $showCameraPicker) {
            CameraPicker { image in
                Task { await uploadUIImage(image) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoPickerSelection) { _, newItem in
            guard let newItem else { return }
            Task { await handlePhotoLibrarySelection(newItem) }
        }
        .alert("Couldn't upload image", isPresented: Binding(
            get: { imageUploadError != nil },
            set: { if !$0 { imageUploadError = nil } }
        ), presenting: imageUploadError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
        .sensoryFeedback(.success, trigger: successCount)
        .sensoryFeedback(.error, trigger: errorCount)
        .task {
            services.prices.startWatching(recordID: currentRecord.id)
            services.recordImages.startWatching(recordID: currentRecord.id)
            await services.coverArt.cacheIfNeeded(record: currentRecord) { newPath in
                Task { @MainActor in
                    self.currentRecord.coverArtStoragePath = newPath
                    await services.records.updateStoragePath(recordID: currentRecord.id, storagePath: newPath)
                }
            }
            // Backfill: mirror any record_images rows that still have a
            // source_url but no storage_path (e.g. inserted on a build
            // before eager-mirroring landed, or from a previous failed run).
            await services.mirrorPendingImages(forRecord: currentRecord.id)
        }
        // Pop the view when the record disappears from local SQLite — covers
        // remote soft-deletes from another device. Status toggles don't fire
        // here because the row still exists with deleted_at null.
        .onChange(of: services.records.records) { _, _ in
            guard !isDismissing else { return }
            Task { await dismissIfDeleted() }
        }
    }

    private func deleteAndDismiss() async {
        isDismissing = true
        await services.records.softDelete(recordID: currentRecord.id)
        dismiss()
    }

    private func dismissIfDeleted() async {
        let stillThere = await services.records.exists(recordID: currentRecord.id)
        if !stillThere {
            isDismissing = true
            dismiss()
        }
    }

    /// Floating menu over the carousel: pick from library, take a photo, or
    /// remove the currently-shown user-uploaded image.
    @ViewBuilder
    private var addImageMenu: some View {
        Menu {
            PhotosPicker(selection: $photoPickerSelection,
                         matching: .images,
                         photoLibrary: .shared()) {
                Label("Choose from library", systemImage: "photo.on.rectangle")
            }
            Button {
                showCameraPicker = true
            } label: {
                Label("Take a photo", systemImage: "camera")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.Colors.accent)
                .background(Circle().fill(.thinMaterial))
        }
    }

    private func handlePhotoLibrarySelection(_ item: PhotosPickerItem) async {
        defer { photoPickerSelection = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            await uploadImageBytes(data)
        } catch {
            imageUploadError = error.localizedDescription
            Log.error(error, category: "records.uploadFromLibrary")
        }
    }

    private func uploadUIImage(_ image: UIImage) async {
        // 0.85 keeps the file under ~500KB for typical phone photos and is
        // visually indistinguishable from full quality on a record cover.
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            imageUploadError = "Couldn't read the image."
            return
        }
        await uploadImageBytes(data)
    }

    private func uploadImageBytes(_ data: Data) async {
        guard let userID = services.auth.currentUserID?.lowerUUID else { return }
        let imageID = UUID().lowerUUID
        do {
            let path = try await services.coverArt.uploadUserImage(
                bytes: data,
                collectionID: currentRecord.collectionID,
                recordID: currentRecord.id,
                imageID: imageID
            )
            await services.recordImages.insertUserUpload(
                recordID: currentRecord.id,
                collectionID: currentRecord.collectionID,
                storagePath: path,
                uploadedBy: userID,
                imageID: imageID
            )
            successCount += 1
        } catch {
            imageUploadError = error.localizedDescription
            Log.error(error, category: "records.uploadUserImage")
            errorCount += 1
        }
    }

    private var detailsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                detailRow("Status", currentRecord.status.label)
                if services.collections.collections.count > 1,
                   let homeName = collectionName(currentRecord.collectionID) {
                    detailRow("Collection", homeName)
                }
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

    private func collectionName(_ id: String) -> String? {
        services.collections.collections.first(where: { $0.id == id })?.name
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
                .captionSecondary()

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
                .captionSecondary()

                if let cents = currentRecord.estimatedPriceCents,
                   let currency = currentRecord.estimatedPriceCurrency {
                    Text(CurrencyFormatter.formatCents(cents, code: currency))
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

    private var priceLogCard: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Logged prices")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.top, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.sm)

                // List (not a VStack of Buttons) so SwiftUI's .swipeActions
                // gives us native swipe-to-delete. scrollDisabled keeps the
                // outer ScrollView in charge of vertical scrolling; the fixed
                // per-row height lets us size the List to its content so it
                // doesn't expand to fill the screen.
                List {
                    ForEach(sortedEntries) { entry in
                        priceLogRow(entry)
                            .listRowBackground(Theme.Colors.surface)
                            .listRowInsets(EdgeInsets(
                                top: 0,
                                leading: Theme.Spacing.lg,
                                bottom: 0,
                                trailing: Theme.Spacing.lg
                            ))
                            .frame(height: Self.priceRowHeight)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await services.prices.delete(entryID: entry.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: Self.priceRowHeight * CGFloat(sortedEntries.count))
                .padding(.bottom, Theme.Spacing.sm)
            }
        }
    }

    private static let priceRowHeight: CGFloat = 56

    private func priceLogRow(_ entry: PriceEntry) -> some View {
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
                    .captionSecondary()
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            } else {
                SecondaryButton(title: "Look up on Discogs", systemImage: "magnifyingglass") {
                    showDiscogsPicker = true
                }
            }
        }
    }

    /// Apply a release picked from the Discogs picker. Overwrites Discogs-
    /// authored facts (title, artist, year, colourway, cover, release id,
    /// estimate, barcode) but preserves notes, status and any logged paid
    /// prices. Clears the cached storage path so the new cover gets re-cached.
    private func applyDiscogsLookup(_ lookup: DiscogsLookup) async {
        var updated = currentRecord
        updated.title = lookup.title
        updated.artist = lookup.artist
        if let y = lookup.year { updated.year = y }
        if let cw = lookup.colourway { updated.colourway = cw }
        if let cover = lookup.coverArtURL { updated.coverArtSourceURL = cover }
        if let bc = lookup.barcode { updated.barcode = bc }
        updated.discogsReleaseID = lookup.releaseID
        updated.coverArtStoragePath = nil
        if let cents = lookup.estimatedPriceCents {
            updated.estimatedPriceCents = cents
            updated.estimatedPriceCurrency = lookup.estimatedCurrency
            updated.estimatedPriceUpdatedAt = Date()
        }
        updated.updatedAt = Date()
        await services.records.upsert(updated)
        await services.ingestDiscogsImages(
            recordID: updated.id,
            collectionID: updated.collectionID,
            sourceURLs: lookup.imageURLs
        )
        currentRecord = updated
        successCount += 1
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
                successCount += 1
            }
        } catch {
            Log.error(error, category: "records.refreshEstimate")
            errorCount += 1
        }
    }

    private func toggleStatus() async {
        var updated = currentRecord
        updated.status = currentRecord.status == .owned ? .wishlist : .owned
        updated.updatedAt = Date()
        currentRecord = updated
        await services.records.upsert(updated)
    }

    /// Collections the user can write to other than the record's current home.
    /// Owner/editor membership only — viewer-only Collections aren't write targets.
    private var writableMoveTargets: [VinylCollection] {
        guard let userID = services.auth.currentUserID?.lowerUUID else { return [] }
        return services.collections.collections.filter { c in
            c.id != currentRecord.collectionID
                && (services.collections.role(in: c.id, userID: userID) == .owner
                    || services.collections.role(in: c.id, userID: userID) == .editor)
        }
    }

    private func move(to collectionID: String) async {
        await services.records.moveToCollection(recordID: currentRecord.id, collectionID: collectionID)
        currentRecord.collectionID = collectionID
        successCount += 1
    }
}

extension PriceEntry {
    var formattedPrice: String {
        CurrencyFormatter.formatMajor(priceMajor, code: currency)
    }
}
