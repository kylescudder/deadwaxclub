import SwiftUI

/// Reverse picker — given a record, pick which lists to add it to.
struct AddRecordToListsSheet: View {
    let record: VinylRecord

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var isSaving = false
    @State private var selectionCount = 0
    @State private var saveCount = 0

    var body: some View {
        NavigationStack {
            Group {
                if services.lists.lists.isEmpty {
                    EmptyState(
                        systemImage: "list.bullet.rectangle",
                        title: "No lists yet",
                        message: "Create a list first, then add records to it."
                    )
                } else {
                    List(services.lists.lists) { list in
                        Button {
                            if selected.contains(list.id) { selected.remove(list.id) }
                            else { selected.insert(list.id) }
                            selectionCount += 1
                        } label: {
                            HStack {
                                Image(systemName: list.shareMode.systemImage)
                                    .foregroundStyle(Theme.Colors.accent)
                                Text(list.name).foregroundStyle(Theme.Colors.textPrimary)
                                Spacer()
                                Image(systemName: selected.contains(list.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(Theme.Colors.accent)
                            }
                        }
                        .listRowBackground(Theme.Colors.surface)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Add to list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(selected.isEmpty || isSaving)
                }
            }
            .sensoryFeedback(.selection, trigger: selectionCount)
            .sensoryFeedback(.success, trigger: saveCount)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        for listID in selected {
            await services.lists.addRecord(record.id, to: listID)
        }
        saveCount += 1
        dismiss()
    }
}
