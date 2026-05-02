import SwiftUI

/// Picker that shows the user's records (owned + wishlist) and lets them
/// multi-select to add to a list.
struct AddRecordsToListSheet: View {
    let listID: String

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { record in
                    Button {
                        if selected.contains(record.id) { selected.remove(record.id) }
                        else { selected.insert(record.id) }
                        Haptics.selection()
                    } label: {
                        HStack {
                            RecordRowView(record: record)
                            Spacer()
                            Image(systemName: selected.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(Theme.Colors.accent)
                        }
                    }
                    .listRowBackground(Theme.Colors.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .searchable(text: $search)
            .navigationTitle("Add records")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selected.count))") { Task { await save() } }
                        .disabled(selected.isEmpty)
                }
            }
        }
    }

    private var filtered: [VinylRecord] {
        let records = services.records.records
        guard !search.isEmpty else { return records }
        let q = search.lowercased()
        return records.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    private func save() async {
        for id in selected {
            await services.lists.addRecord(id, to: listID)
        }
        Haptics.success()
        dismiss()
    }
}
