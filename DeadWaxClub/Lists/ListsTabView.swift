import SwiftUI

struct ListsTabView: View {
    @EnvironmentObject private var services: AppServices
    @State private var showCreate = false
    /// Set by CreateListView's onCreated callback to push the user straight
    /// into the new list rather than dropping them back at the lists list.
    @State private var navTarget: VinylList?

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
                        NavigationLink {
                            ListDetailView(list: list)
                        } label: {
                            ListRowView(list: list)
                        }
                        .listRowBackground(Theme.Colors.surface)
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
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
            NavigationStack {
                CreateListView { created in
                    navTarget = created
                }
            }
        }
        // Programmatic push for the post-create flow. Inline NavigationLink
        // above handles taps; declaring both an inline destination and a
        // `navigationDestination(for: VinylList.self)` makes SwiftUI warn
        // and silently picks one of them.
        .navigationDestination(item: $navTarget) { list in
            ListDetailView(list: list)
        }
        .onAppear {
            if let userID = services.auth.currentUserID?.lowerUUID {
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
                    .captionSecondary()
            }
            Spacer()
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}
