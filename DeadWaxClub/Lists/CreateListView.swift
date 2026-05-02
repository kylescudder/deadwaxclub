import SwiftUI

struct CreateListView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var mode: ListShareMode = .private
    @State private var isSaving = false

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
                        Haptics.selection()
                    } label: {
                        HStack {
                            Image(systemName: option.systemImage)
                                .foregroundStyle(Theme.Colors.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).foregroundStyle(Theme.Colors.textPrimary)
                                Text(option.detail)
                                    .font(.caption)
                                    .foregroundStyle(Theme.Colors.textSecondary)
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
        _ = await services.lists.create(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description,
            mode: mode
        )
        Haptics.success()
        dismiss()
    }
}
