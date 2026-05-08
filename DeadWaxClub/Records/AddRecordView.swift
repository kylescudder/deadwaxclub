import SwiftUI
import PhotosUI

/// Single form for both adding a new record and editing an existing one.
/// Pass `existing` to edit; nil to add. Title and save semantics adapt.
struct AddRecordView: View {
    let initialStatus: RecordStatus
    let existing: VinylRecord?

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var artist = ""
    @State private var year = ""
    @State private var colourway = ""
    @State private var barcode = ""
    @State private var notes = ""
    @State private var status: RecordStatus
    @State private var coverURL = ""
    @State private var isSaving = false
    @State private var attachedReleaseID: Int64?
    @State private var attachedEstimateCents: Int?
    @State private var attachedEstimateCurrency: String?
    /// Captured from the Discogs picker so we can persist every image (not just
    /// the primary cover) into record_images on save.
    @State private var attachedImageURLs: [String] = []
    @State private var showDiscogsPicker = false
    @State private var lookupError: String?
    @State private var selectedCollectionID: String?
    /// Photos selected from the library / camera before save. Each entry is
    /// the raw JPEG bytes — we don't have a record id yet, so the upload is
    /// deferred to `save()` once the record exists.
    @State private var pendingPhotos: [Data] = []
    @State private var photoPickerSelection: PhotosPickerItem?
    @State private var showCameraPicker = false
    @State private var photoError: String?

    init(initialStatus: RecordStatus, existing: VinylRecord? = nil) {
        self.initialStatus = initialStatus
        self.existing = existing
        self._status = State(initialValue: existing?.status ?? initialStatus)
    }

    var body: some View {
        Form {
            Section("Details") {
                TextField("Title", text: $title)
                TextField("Artist", text: $artist)
                TextField("Year", text: $year).keyboardType(.numberPad)
                TextField("Colour way", text: $colourway)
            }
            Section("Identification") {
                TextField("Barcode", text: $barcode).keyboardType(.numberPad)
                TextField("Cover art URL", text: $coverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    showDiscogsPicker = true
                } label: {
                    Label(
                        attachedReleaseID == nil ? "Find on Discogs" : "Discogs release attached",
                        systemImage: attachedReleaseID == nil ? "magnifyingglass" : "checkmark.circle.fill"
                    )
                }
                if let lookupError {
                    Text(lookupError).font(.footnote).foregroundStyle(.red)
                }
            }
            Section {
                Picker("Status", selection: $status) {
                    ForEach(RecordStatus.allCases) { Text($0.label).tag($0) }
                }
            }
            if writableCollections.count > 1 {
                Section {
                    Picker("Collection", selection: $selectedCollectionID) {
                        ForEach(writableCollections) { c in
                            Text(c.name).tag(Optional(c.id))
                        }
                    }
                } header: {
                    Text("Save to")
                } footer: {
                    Text("Records in your personal Collection are private; records in a shared Collection are visible to its members.")
                }
            }
            Section {
                photosRow
                if let photoError {
                    Text(photoError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Your photos")
            } footer: {
                Text("Optional. Added in addition to anything Discogs provides; uploaded after the record is saved.")
            }
            Section("Notes") {
                TextField("Optional", text: $notes, axis: .vertical).lineLimit(3...)
            }
        }
        .navigationTitle(existing == nil ? "Add record" : "Edit record")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!isValid || isSaving)
            }
        }
        .onAppear { populate() }
        .sheet(isPresented: $showDiscogsPicker) {
            DiscogsPickerView(initialTitle: title, initialArtist: artist) { lookup in
                applyLookup(lookup)
            }
        }
        .sheet(isPresented: $showCameraPicker) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.85) {
                    pendingPhotos.append(data)
                    Haptics.success()
                } else {
                    photoError = "Couldn't read the image."
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoPickerSelection) { _, newItem in
            guard let newItem else { return }
            Task { await loadPickedPhoto(newItem) }
        }
    }

    @ViewBuilder
    private var photosRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(Array(pendingPhotos.enumerated()), id: \.offset) { idx, data in
                        if let ui = UIImage(data: data) {
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: ui)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Button {
                                    pendingPhotos.remove(at: idx)
                                    Haptics.tap()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                        .font(.caption)
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                }
            }
            Spacer()
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
                Label("Add", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .padding(8)
                    .background(Circle().fill(Theme.Colors.surfaceElevated))
            }
        }
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        defer { photoPickerSelection = nil }
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                await MainActor.run { pendingPhotos.append(data) }
                Haptics.success()
            }
        } catch {
            photoError = error.localizedDescription
            Log.error(error, category: "addrecord.loadPickedPhoto")
        }
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !artist.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Collections the user can write to. Editing keeps the record's current
    /// home; new records default to the user's primary Collection.
    private var writableCollections: [VinylCollection] {
        guard let userID = services.auth.currentUserID?.uuidString.lowercased() else { return [] }
        return services.collections.collections.filter { c in
            let role = services.collections.role(in: c.id, userID: userID)
            return role == .owner || role == .editor
        }
    }

    private func populate() {
        if let existing {
            title = existing.title
            artist = existing.artist
            year = existing.year.map(String.init) ?? ""
            colourway = existing.colourway ?? ""
            barcode = existing.barcode ?? ""
            notes = existing.notes ?? ""
            coverURL = existing.coverArtSourceURL ?? ""
            attachedReleaseID = existing.discogsReleaseID
            attachedEstimateCents = existing.estimatedPriceCents
            attachedEstimateCurrency = existing.estimatedPriceCurrency
            selectedCollectionID = existing.collectionID
        } else if selectedCollectionID == nil {
            selectedCollectionID = services.profile.profile?.primaryCollectionID
        }
    }

    /// Pulled from the picker. Overwrites the user's typed facts because
    /// they explicitly chose this release; preserves notes/status.
    private func applyLookup(_ lookup: DiscogsLookup) {
        title = lookup.title
        artist = lookup.artist
        if let y = lookup.year { year = String(y) }
        if let cw = lookup.colourway { colourway = cw }
        if let cover = lookup.coverArtURL { coverURL = cover }
        if let bc = lookup.barcode { barcode = bc }
        attachedReleaseID = lookup.releaseID
        attachedEstimateCents = lookup.estimatedPriceCents
        attachedEstimateCurrency = lookup.estimatedCurrency
        attachedImageURLs = lookup.imageURLs
        lookupError = nil
        Haptics.success()
    }

    private func save() async {
        // Picker selection wins; otherwise stay in the existing record's
        // Collection (when editing) or default to the user's primary.
        let resolvedCollectionID: String? = selectedCollectionID
            ?? existing?.collectionID
            ?? services.profile.profile?.primaryCollectionID
        guard let collectionID = resolvedCollectionID else { return }
        isSaving = true
        defer { isSaving = false }

        // If the user typed a barcode and we don't already have a Discogs
        // release attached, try the lookup automatically before saving.
        let trimmedBarcode = barcode.trimmingCharacters(in: .whitespaces)
        var enrichment: DiscogsLookup?
        if !trimmedBarcode.isEmpty && attachedReleaseID == nil {
            do {
                enrichment = try await services.discogs.lookup(barcode: trimmedBarcode)
            } catch DiscogsClient.LookupError.noResults {
                // Save anyway — user can attach via the picker later.
            } catch {
                Log.error(error, category: "addrecord.barcodeLookup")
            }
        }

        let now = Date()
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespaces)

        let resolvedTitle = trimmedTitle.isEmpty ? (enrichment?.title ?? "") : trimmedTitle
        let resolvedArtist = trimmedArtist.isEmpty ? (enrichment?.artist ?? "") : trimmedArtist
        let resolvedYear = Int(year) ?? enrichment?.year
        let resolvedColourway = colourway.isEmpty ? enrichment?.colourway : colourway
        let resolvedCoverURL = coverURL.isEmpty ? enrichment?.coverArtURL : coverURL
        let resolvedBarcode = trimmedBarcode.isEmpty ? enrichment?.barcode : trimmedBarcode
        let resolvedReleaseID = attachedReleaseID ?? enrichment?.releaseID ?? existing?.discogsReleaseID
        let resolvedEstimateCents = attachedEstimateCents ?? enrichment?.estimatedPriceCents ?? existing?.estimatedPriceCents
        let resolvedEstimateCurrency = attachedEstimateCurrency ?? enrichment?.estimatedCurrency ?? existing?.estimatedPriceCurrency
        let resolvedEstimateUpdatedAt: Date? = {
            if attachedEstimateCents != nil || enrichment?.estimatedPriceCents != nil { return now }
            return existing?.estimatedPriceUpdatedAt
        }()

        let record = VinylRecord(
            id: existing?.id ?? UUID().uuidString.lowercased(),
            collectionID: collectionID,
            status: status,
            title: resolvedTitle,
            artist: resolvedArtist,
            year: resolvedYear,
            colourway: resolvedColourway,
            coverArtSourceURL: resolvedCoverURL,
            coverArtStoragePath: resolvedReleaseID == existing?.discogsReleaseID ? existing?.coverArtStoragePath : nil,
            discogsReleaseID: resolvedReleaseID,
            barcode: resolvedBarcode,
            notes: notes.isEmpty ? nil : notes,
            estimatedPriceCents: resolvedEstimateCents,
            estimatedPriceCurrency: resolvedEstimateCurrency,
            estimatedPriceUpdatedAt: resolvedEstimateUpdatedAt,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            deletedAt: nil
        )
        await services.records.upsert(record)
        // Persist all Discogs images for the carousel. Priority:
        // 1. Captured array from the Discogs picker (covers all images)
        // 2. Barcode-driven enrichment fetched at save time
        // 3. The typed cover URL alone, as a final fallback.
        let imageSources: [String] = !attachedImageURLs.isEmpty
            ? attachedImageURLs
            : (enrichment?.imageURLs.isEmpty == false
                ? enrichment!.imageURLs
                : [resolvedCoverURL].compactMap { $0 })
        if !imageSources.isEmpty {
            await services.ingestDiscogsImages(
                recordID: record.id,
                collectionID: record.collectionID,
                sourceURLs: imageSources
            )
        }
        // Upload any photos the user picked / shot in this form. They append
        // to whatever Discogs already supplied (so position 0 stays the cover).
        if !pendingPhotos.isEmpty,
           let userID = services.auth.currentUserID?.uuidString.lowercased() {
            for data in pendingPhotos {
                let imageID = UUID().uuidString.lowercased()
                do {
                    let path = try await services.coverArt.uploadUserImage(
                        bytes: data,
                        collectionID: record.collectionID,
                        recordID: record.id,
                        imageID: imageID
                    )
                    await services.recordImages.insertUserUpload(
                        recordID: record.id,
                        collectionID: record.collectionID,
                        storagePath: path,
                        uploadedBy: userID,
                        imageID: imageID
                    )
                } catch {
                    Log.error(error, category: "addrecord.uploadUserImage")
                }
            }
        }
        Haptics.success()
        dismiss()
    }
}
