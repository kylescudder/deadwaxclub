import AppIntents

struct DeadWaxClubShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogPriceIntent(),
            phrases: [
                "Log a price in \(.applicationName)",
                "Track a vinyl price with \(.applicationName)",
            ],
            shortTitle: "Log price",
            systemImageName: "tag"
        )
        AppShortcut(
            intent: OpenRecordIntent(),
            phrases: [
                "Open a record in \(.applicationName)",
                "Show me a vinyl in \(.applicationName)",
            ],
            shortTitle: "Open record",
            systemImageName: "opticaldisc"
        )
    }
}
