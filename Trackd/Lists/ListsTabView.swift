import SwiftUI

/// Placeholder. Full lists / sharing UI lands in a follow-up commit.
struct ListsTabView: View {
    var body: some View {
        EmptyState(
            systemImage: "list.bullet.rectangle",
            title: "Lists are coming",
            message: "Curated lists with sharing — public links, invites, or collaborative editing — land in the next update."
        )
        .navigationTitle("Lists")
    }
}
