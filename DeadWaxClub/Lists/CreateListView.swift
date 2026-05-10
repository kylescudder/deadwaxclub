import SwiftUI

struct CreateListView: View {
    /// Called after the list has been created, before the sheet dismisses,
    /// so the parent can navigate the user straight into the new list.
    var onCreated: ((VinylList) -> Void)? = nil

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var mode: ListShareMode = .private
    @State private var isSaving = false
    @State private var selectionCount = 0
    @State private var saveCount = 0

    var body: some View {
        Form {
            Section("Details") {
                TextField("Name", text: $name)
                TextField("Description (optional)", text: $description, axis: .vertical)
                    .lineLimit(2...)
            }
            Section("Sharing") {
                ForEach(ListShareMode.allCases) { option in
                    Button {
                        mode = option
                        selectionCount += 1
                    } label: {
                        HStack {
                            Image(systemName: option.systemImage)
                                .foregroundStyle(Theme.Colors.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).foregroundStyle(Theme.Colors.textPrimary)
                                Text(option.detail)
                                    .captionSecondary()
                            }
                            Spacer()
                            if mode == option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.Colors.accent)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("New list")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: selectionCount)
        .sensoryFeedback(.success, trigger: saveCount)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { Task { await create() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        }
    }

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        let created = await services.lists.create(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description,
            mode: mode
        )
        saveCount += 1
        if let created {
            onCreated?(created)
        }
        dismiss()
    }
}
