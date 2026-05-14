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
                        // Only owners can destroy a list. Collaborators /
                        // viewers on someone else's collaborative or shared
                        // list see no swipe affordance — they aren't allowed
                        // to delete the underlying list, only the owner is.
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if isOwner(of: list) {
                                Button(role: .destructive) {
                                    Task { await services.lists.softDelete(listID: list.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    }
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

    private func isOwner(of list: VinylList) -> Bool {
        guard let userID = services.auth.currentUserID?.lowerUUID else { return false }
        return list.ownerID == userID
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
