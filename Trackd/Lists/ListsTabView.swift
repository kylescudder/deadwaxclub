import SwiftUI

struct ListsTabView: View {
    @EnvironmentObject private var services: AppServices
    @State private var showCreate = false

    var body: some View {
        Group {
            if services.lists.lists.isEmpty {
                EmptyState(
                    systemImage: "list.bullet.rectangle",
                    title: "No lists yet",
                    message: "Curate sets of records to share with friends — keep them private, share a public link, or invite others to collaborate.",
                    actionTitle: "Create a list"
                ) { showCreate = true }
            } else {
                List {
                    ForEach(services.lists.lists) { list in
                        NavigationLink(value: list) {
                            ListRowView(list: list)
                        }
                        .listRowBackground(Theme.Colors.surface)
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .navigationDestination(for: VinylList.self) { list in
                    ListDetailView(list: list)
                }
            }
        }
        .background(Theme.Colors.background)
        .navigationTitle("Lists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack { CreateListView() }
        }
        .onAppear {
            if let userID = services.auth.currentUserID?.uuidString {
                services.lists.startWatching(userID: userID)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let toRemove = offsets.map { services.lists.lists[$0] }
        Task { for l in toRemove { await services.lists.softDelete(listID: l.id) } }
    }
}

private struct ListRowView: View {
    let list: VinylList

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: list.shareMode.systemImage)
                .font(.title3)
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name).font(.callout.weight(.semibold))
                Text(list.shareMode.label)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}
