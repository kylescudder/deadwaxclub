import SwiftUI

/// Reverse picker — given a record, pick which lists to add it to.
struct AddRecordToListsSheet: View {
    let record: VinylRecord

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var isSaving = false
    @State private var showCreateList = false
    @State private var selectionCount = 0
    @State private var saveCount = 0

    var body: some View {
        NavigationStack {
            Group {
                if services.lists.lists.isEmpty {
                    EmptyState(
                        systemImage: "list.bullet.rectangle",
                        title: "No lists yet",
                        message: "Create your first list, then add this record to it.",
                        actionTitle: "Create a list",
                        action: { showCreateList = true }
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
            .sheet(isPresented: $showCreateList) {
                NavigationStack {
                    CreateListView { created in
                        // Auto-add the current record to the new list and
                        // close this sheet — the user opened "Add to list"
                        // to do exactly this, so don't make them tap twice.
                        // addRecord continues in the background after dismiss.
                        Task { await services.lists.addRecord(record.id, to: created.id) }
                        saveCount += 1
                        dismiss()
                    }
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
