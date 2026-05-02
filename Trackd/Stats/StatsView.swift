import SwiftUI

/// Placeholder. Full stats screen lands in a follow-up commit.
struct StatsView: View {
    var body: some View {
        EmptyState(
            systemImage: "chart.bar",
            title: "Stats are coming",
            message: "Total spent, collection value, and breakdowns by decade and colour way land in the next update."
        )
        .navigationTitle("Stats")
    }
}
