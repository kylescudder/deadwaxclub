import SwiftUI

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
    @State private var showDiscogsPicker = false
    @State private var lookupError: String?

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
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !artist.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func populate() {
        guard let existing else { return }
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
        lookupError = nil
        Haptics.success()
    }

    private func save() async {
        guard let ownerID = services.auth.currentUserID?.uuidString.lowercased() else { return }
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
            ownerID: ownerID,
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
        Haptics.success()
        dismiss()
    }
}
