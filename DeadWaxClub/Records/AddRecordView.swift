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
    }

    private func save() async {
        guard let ownerID = services.auth.currentUserID?.uuidString else { return }
        isSaving = true
        defer { isSaving = false }

        let now = Date()
        let record = VinylRecord(
            id: existing?.id ?? UUID().uuidString.lowercased(),
            ownerID: ownerID,
            status: status,
            title: title.trimmingCharacters(in: .whitespaces),
            artist: artist.trimmingCharacters(in: .whitespaces),
            year: Int(year),
            colourway: colourway.isEmpty ? nil : colourway,
            coverArtSourceURL: coverURL.isEmpty ? nil : coverURL,
            coverArtStoragePath: existing?.coverArtStoragePath,
            discogsReleaseID: existing?.discogsReleaseID,
            barcode: barcode.isEmpty ? nil : barcode,
            notes: notes.isEmpty ? nil : notes,
            estimatedPriceCents: existing?.estimatedPriceCents,
            estimatedPriceCurrency: existing?.estimatedPriceCurrency,
            estimatedPriceUpdatedAt: existing?.estimatedPriceUpdatedAt,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            deletedAt: nil
        )
        await services.records.upsert(record)
        Haptics.success()
        dismiss()
    }
}
